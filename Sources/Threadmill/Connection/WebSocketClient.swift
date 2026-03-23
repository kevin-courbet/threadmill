import Foundation

enum WebSocketClientError: LocalizedError {
    case notConnected
    case invalidJSON
    case requestTimedOut(method: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "WebSocket is not connected."
        case .invalidJSON:
            "Received invalid JSON payload."
        case let .requestTimedOut(method):
            "Request timed out for method \(method)."
        }
    }
}

struct JSONRPCErrorResponse: LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? {
        "JSON-RPC error \(code): \(message)"
    }
}

@MainActor
final class WebSocketClient: NSObject, WebSocketManaging {
    var onEvent: ((String, [String: Any]?) -> Void)?
    var onBinaryMessage: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Any, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var isManualDisconnect = false

    var isConnected: Bool {
        socketTask != nil
    }

    func connect(to url: URL) {
        guard socketTask == nil else {
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let socketTask = session.webSocketTask(with: url)

        self.session = session
        self.socketTask = socketTask
        self.isManualDisconnect = false

        socketTask.resume()
        receiveNextMessage()
    }

    func disconnect() {
        isManualDisconnect = true
        failAllPendingRequests(error: WebSocketClientError.notConnected)
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func sendRequest(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Any {
        guard let socketTask else {
            throw WebSocketClientError.notConnected
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw WebSocketClientError.invalidJSON
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.timeoutPendingRequest(id: requestID)
            }

            pendingRequests[requestID] = PendingRequest(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            socketTask.send(.string(jsonText)) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    if let error {
                        self.finishPendingRequest(id: requestID, result: .failure(error))
                    }
                }
            }
        }
    }

    func sendBinaryFrame(_ data: Data) async throws {
        guard let socketTask else {
            throw WebSocketClientError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socketTask.send(.data(data)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receiveNextMessage() {
        guard let socketTask else {
            return
        }

        socketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                switch result {
                case let .success(message):
                    self.handleMessage(message)
                    self.receiveNextMessage()

                case let .failure(error):
                    self.handleSocketFailure(error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            handleJSONString(text)

        case let .data(data):
            onBinaryMessage?(data)

        @unknown default:
            break
        }
    }

    private func handleJSONString(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = object as? [String: Any]
        else {
            return
        }

        if json["id"] == nil {
            guard let method = json["method"] as? String else {
                return
            }

            onEvent?(method, json["params"] as? [String: Any])
            return
        }

        guard let id = parseResponseID(json["id"]) else {
            return
        }

        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown error"
            finishPendingRequest(id: id, result: .failure(JSONRPCErrorResponse(code: code, message: message)))
            return
        }

        let result = json["result"] ?? NSNull()
        finishPendingRequest(id: id, result: .success(result))
    }

    private func parseResponseID(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }

        if let stringValue = value as? String {
            return Int(stringValue)
        }

        return nil
    }

    private func finishPendingRequest(id: Int, result: Result<Any, Error>) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }

        pending.timeoutTask.cancel()
        nonisolated(unsafe) let unsafeResult = result
        pending.continuation.resume(with: unsafeResult)
    }

    private func timeoutPendingRequest(id: Int) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }

        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: WebSocketClientError.requestTimedOut(method: pending.method))
    }

    private func failAllPendingRequests(error: Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func handleSocketFailure(_ error: Error?) {
        let shouldNotify = !isManualDisconnect
        isManualDisconnect = false

        failAllPendingRequests(error: error ?? WebSocketClientError.notConnected)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil

        if shouldNotify {
            onDisconnect?(error)
        }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        // Handshake complete — receive loop already started in connect()
    }

    nonisolated func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith _: URLSessionWebSocketTask.CloseCode,
        reason _: Data?
    ) {
        Task { @MainActor [weak self] in
            self?.handleSocketFailure(nil)
        }
    }

    nonisolated func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }

        Task { @MainActor [weak self] in
            self?.handleSocketFailure(error)
        }
    }
}
