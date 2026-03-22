import Foundation

enum SpindleConnectionError: LocalizedError {
    case notConnected
    case invalidResponse
    case rpcError(String)
    case timedOut(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket is not connected."
        case .invalidResponse:
            return "Received invalid RPC response."
        case let .rpcError(message):
            return "RPC error: \(message)"
        case let .timedOut(message):
            return "Timed out: \(message)"
        case .disconnected:
            return "WebSocket disconnected."
        }
    }
}

struct ACPRequestPayload<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// Lightweight WebSocket client for Spindle integration tests.
/// Speaks Spindle's JSON-RPC text frames and binary channel frames.
final class SpindleConnection: @unchecked Sendable {
    private let url = URL(string: "ws://127.0.0.1:19990")!
    private let lock = NSLock()

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    private var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 1
    private var receivedEvents: [(String, [String: Any]?)] = []
    private var binaryFrames: [Data] = []

    func connect() async throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func handshake() async throws {
        _ = try await rpc(
            "session.hello",
            params: [
                "client": [
                    "name": "threadmill-integration-tests",
                    "version": "dev",
                ],
                "protocol_version": "2026-03-17",
                "capabilities": [
                    "state.delta.operations.v1",
                    "preset.output.v1",
                    "rpc.errors.structured.v1",
                ],
            ]
        )
    }

    func rpc(_ method: String, params: [String: Any]?, timeout: TimeInterval = 20) async throws -> Any {
        guard let task else {
            throw SpindleConnectionError.notConnected
        }

        let requestID = withLock {
            let id = nextID
            nextID += 1
            return id
        }

        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
        ]
        if let params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestString = String(data: requestData, encoding: .utf8)!

        // Register continuation BEFORE send — if the response arrives between
        // send() returning and the continuation being stored, it would be dropped.
        return try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                self.withLock {
                    self.pendingRequests[requestID] = continuation
                }
                Task {
                    do {
                        try await task.send(.string(requestString))
                    } catch {
                        self.failPendingRequest(requestID, with: error)
                    }
                }
            }
        }
    }

    func sendBinary(_ data: Data) async throws {
        guard let task else {
            throw SpindleConnectionError.notConnected
        }
        try await task.send(.data(data))
    }

    func waitForEvent(_ method: String, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let params = popEvent(method: method) {
                return params ?? [:]
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw SpindleConnectionError.timedOut("event \(method)")
    }

    func waitForBinaryFrame(channelID: UInt16, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let frame = popBinaryFrame(channelID: channelID) {
                return frame
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        throw SpindleConnectionError.timedOut("binary frame for channel \(channelID)")
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        // Resume pending continuations BEFORE cancelling the socket —
        // the detached send Task in rpc() may still be in-flight and
        // would call failPendingRequest on an already-drained map.
        let continuations = withLock {
            let values = Array(pendingRequests.values)
            pendingRequests.removeAll()
            return values
        }
        for continuation in continuations {
            continuation.resume(throwing: SpindleConnectionError.disconnected)
        }

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    private func receiveLoop() async {
        guard let task else {
            return
        }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    try handleJSONData(Data(text.utf8))
                case let .data(data):
                    if isJSON(data) {
                        try handleJSONData(data)
                    } else {
                        withLock {
                            binaryFrames.append(data)
                        }
                    }
                @unknown default:
                    break
                }
            } catch {
                // URLSession cancellation (-999) and socket-not-connected (57) are
                // expected during teardown — don't fail pending requests.
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    return
                }
                if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                    return
                }
                let continuations = withLock {
                    let values = Array(pendingRequests.values)
                    pendingRequests.removeAll()
                    return values
                }
                for continuation in continuations {
                    continuation.resume(throwing: error)
                }
                return
            }
        }
    }

    private func handleJSONData(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            throw SpindleConnectionError.invalidResponse
        }

        if let idValue = json["id"], let id = intValue(from: idValue) {
            if let errorDict = json["error"] as? [String: Any] {
                let message = errorDict["message"] as? String ?? "unknown error"
                failPendingRequest(id, with: SpindleConnectionError.rpcError(message))
                return
            }

            guard let result = json["result"] else {
                failPendingRequest(id, with: SpindleConnectionError.invalidResponse)
                return
            }
            resolvePendingRequest(id, with: result)
            return
        }

        if let method = json["method"] as? String {
            withLock {
                receivedEvents.append((method, json["params"] as? [String: Any]))
                if receivedEvents.count > 500 {
                    receivedEvents.removeFirst(receivedEvents.count - 500)
                }
            }
        }
    }

    private func intValue(from value: Any) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func resolvePendingRequest(_ id: Int, with result: Any) {
        let continuation = withLock {
            pendingRequests.removeValue(forKey: id)
        }
        continuation?.resume(returning: result)
    }

    private func failPendingRequest(_ id: Int, with error: Error) {
        let continuation = withLock {
            pendingRequests.removeValue(forKey: id)
        }
        continuation?.resume(throwing: error)
    }

    private func popEvent(method: String) -> [String: Any]?? {
        withLock {
            guard let index = receivedEvents.firstIndex(where: { $0.0 == method }) else {
                return nil
            }
            return receivedEvents.remove(at: index).1
        }
    }

    private func popBinaryFrame(channelID: UInt16) -> Data? {
        withLock {
            guard let index = binaryFrames.firstIndex(where: { frame in
                guard frame.count >= 2 else {
                    return false
                }
                let frameChannelID = (UInt16(frame[0]) << 8) | UInt16(frame[1])
                return frameChannelID == channelID
            }) else {
                return nil
            }
            return binaryFrames.remove(at: index)
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpindleConnectionError.timedOut("RPC response")
            }

            guard let result = try await group.next() else {
                throw SpindleConnectionError.timedOut("RPC response")
            }
            group.cancelAll()
            return result
        }
    }

    private func isJSON(_ data: Data) -> Bool {
        guard let first = data.first else {
            return false
        }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
