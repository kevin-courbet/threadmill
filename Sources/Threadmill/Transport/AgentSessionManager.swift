import ACPModel
import Foundation
import Observation
import os

enum AgentSessionManagerError: LocalizedError {
    case unknownChannel(UInt16)
    case invalidBinaryFrame
    case rpcError(String)
    case requestTimedOut
    case channelDisconnected(UInt16)

    var errorDescription: String? {
        switch self {
        case let .unknownChannel(channelID):
            return "Unknown agent channel: \(channelID)."
        case .invalidBinaryFrame:
            return "Invalid binary frame."
        case let .rpcError(message):
            return message
        case .requestTimedOut:
            return "Agent RPC timed out."
        case let .channelDisconnected(channelID):
            return "Agent channel is disconnected: \(channelID)."
        }
    }
}

@MainActor
@Observable
final class AgentSessionManager {
    private struct ChannelContext {
        let sessionID: String
        let onUpdate: (SessionUpdateNotification) -> Void
    }

    private struct PendingRequestKey: Hashable {
        let channelID: UInt16
        let requestID: String
    }

    private let connectionManager: any ConnectionManaging
    private let managedConnectionID: ObjectIdentifier

    private(set) var reconnectEpoch: UInt64 = 0

    private var channelsByID: [UInt16: ChannelContext] = [:]
    private var incomingBuffers: [UInt16: Data] = [:]
    private var nextRequestIDByChannel: [UInt16: Int] = [:]
    private var pendingRequests: [PendingRequestKey: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    init(connectionManager: any ConnectionManaging) {
        self.connectionManager = connectionManager
        managedConnectionID = ObjectIdentifier(connectionManager as AnyObject)
    }

    func attachChannel(channelID: UInt16, sessionID: String, onUpdate: @escaping (SessionUpdateNotification) -> Void) {
        Logger.agent.info("asm.attachChannel ch=\(channelID) session=\(sessionID, privacy: .public) registered=\(self.channelsByID.keys.sorted().map(String.init).joined(separator: ","), privacy: .public)")
        channelsByID[channelID] = ChannelContext(sessionID: sessionID, onUpdate: onUpdate)
        incomingBuffers[channelID] = Data()
    }

    func detachChannel(channelID: UInt16) {
        cleanupChannel(channelID: channelID, pendingError: AgentSessionManagerError.channelDisconnected(channelID))
    }

    func sendFrame(channelID: UInt16, payload: Data) async throws {
        guard channelsByID[channelID] != nil else {
            throw AgentSessionManagerError.unknownChannel(channelID)
        }

        var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
        frame.append(payload)
        frame.append(0x0A)
        try await connectionManager.sendBinaryFrame(frame)
    }

    func sendPrompt(text: String, channelID: UInt16, sessionID: String) async throws {
        let _: SessionPromptResponse = try await sendRequest(
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(sessionID),
                prompt: [.text(TextContent(text: text))]
            ),
            channelID: channelID,
            timeout: 120
        )
    }

    func cancelPrompt(channelID: UInt16, sessionID: String) async throws {
        try await sendNotification(
            method: "session/cancel",
            params: CancelSessionRequest(sessionId: SessionId(sessionID)),
            channelID: channelID
        )
    }

    func setMode(channelID: UInt16, sessionID: String, modeID: String) async throws {
        let _: SetModeResponse = try await sendRequest(
            method: "session/set_mode",
            params: SetModeRequest(sessionId: SessionId(sessionID), modeId: modeID),
            channelID: channelID,
            timeout: 20
        )
    }

    func setModel(channelID: UInt16, sessionID: String, modelID: String) async throws {
        let _: SetModelResponse = try await sendRequest(
            method: "session/set_model",
            params: SetModelRequest(sessionId: SessionId(sessionID), modelId: modelID),
            channelID: channelID,
            timeout: 20
        )
    }

    func setConfigOption(channelID: UInt16, sessionID: String, key: String, value: SessionConfigOptionValue) async throws {
        let _: SetSessionConfigOptionResponse = try await sendRequest(
            method: "session/set_config_option",
            params: SetSessionConfigOptionRequest(
                sessionId: SessionId(sessionID),
                configId: SessionConfigId(key),
                value: value
            ),
            channelID: channelID,
            timeout: 20
        )
    }

    func loadSession(channelID: UInt16, sessionID: String) async throws -> LoadSessionResponse {
        try await sendRequest(
            method: "session/load",
            params: LoadSessionRequest(sessionId: SessionId(sessionID)),
            channelID: channelID,
            timeout: 20
        )
    }

    func listSessions(channelID: UInt16) async throws -> ListSessionsResponse {
        try await sendRequest(
            method: "session/list",
            params: ListSessionsRequest(),
            channelID: channelID,
            timeout: 20
        )
    }

    func handleConnectionStateChanged(_ status: ConnectionStatus, on connection: any ConnectionManaging) {
        guard isManagedConnection(connection) else {
            return
        }

        switch status {
        case .disconnected, .reconnecting:
            markAllChannelsDisconnected()
            reconnectEpoch &+= 1
        case .connecting, .connected:
            break
        }
    }

    func handleConnectionReconnected(on connection: any ConnectionManaging) async {
        guard isManagedConnection(connection) else {
            return
        }

        reconnectEpoch &+= 1
    }

    func handleBinaryFrame(_ frame: Data) {
        handleBinaryFrame(frame, from: connectionManager)
    }

    func handleBinaryFrame(_ frame: Data, from connection: any ConnectionManaging) {
        guard isManagedConnection(connection) else {
            return
        }

        guard frame.count >= 2 else {
            Logger.agent.error("Received invalid ACP frame, missing channel header")
            return
        }

        let channelID = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        Logger.agent.info("asm.binaryFrame ch=\(channelID) bytes=\(frame.count) registered=\(self.channelsByID.keys.sorted().map(String.init).joined(separator: ","), privacy: .public)")
        guard channelsByID[channelID] != nil else {
            Logger.agent.info("asm.binaryFrame DROPPED ch=\(channelID)")
            return
        }

        var buffer = incomingBuffers[channelID] ?? Data()
        buffer.append(frame.dropFirst(2))

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)

            guard !line.isEmpty else {
                continue
            }

            do {
                let message = try JSONDecoder().decode(Message.self, from: line)
                handleMessage(message, channelID: channelID)
            } catch {
                Logger.agent.error("Failed to decode ACP message on channel \(channelID): \(error)")
            }
        }

        incomingBuffers[channelID] = buffer
    }

    private func sendNotification<Params: Encodable>(
        method: String,
        params: Params,
        channelID: UInt16
    ) async throws {
        let paramsData = try JSONEncoder().encode(params)
        let paramsValue = try JSONDecoder().decode(AnyCodable.self, from: paramsData)
        let payload = try JSONEncoder().encode(JSONRPCNotification(method: method, params: paramsValue))
        try await sendFrame(channelID: channelID, payload: payload)
    }

    private func sendRequest<Response: Decodable, Params: Encodable>(
        method: String,
        params: Params,
        channelID: UInt16,
        timeout: TimeInterval
    ) async throws -> Response {
        let requestID = nextRequestID(channelID: channelID)
        let requestIDString = requestID.description
        let paramsData = try JSONEncoder().encode(params)
        let paramsValue = try JSONDecoder().decode(AnyCodable.self, from: paramsData)
        let request = JSONRPCRequest(id: requestID, method: method, params: paramsValue)
        let payload = try JSONEncoder().encode(request)

        let key = PendingRequestKey(channelID: channelID, requestID: requestIDString)
        let response: JSONRPCResponse
        do {
            response = try await withThrowingTaskGroup(of: JSONRPCResponse.self) { group in
                group.addTask {
                    try await self.awaitResponse(
                        key: key,
                        payload: payload,
                        channelID: channelID,
                        requestID: requestIDString
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AgentSessionManagerError.requestTimedOut
                }

                guard let firstResult = try await group.next() else {
                    throw AgentSessionManagerError.rpcError("No RPC response task result")
                }
                group.cancelAll()
                return firstResult
            }
        } catch {
            resumePendingRequest(
                channelID: channelID,
                requestID: requestIDString,
                with: .failure(AgentSessionManagerError.requestTimedOut)
            )
            throw error
        }

        if let rpcError = response.error {
            throw AgentSessionManagerError.rpcError(rpcError.message)
        }
        guard let result = response.result else {
            throw AgentSessionManagerError.rpcError("Missing RPC result for \(method)")
        }
        let resultData = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(Response.self, from: resultData)
    }

    private func awaitResponse(
        key: PendingRequestKey,
        payload: Data,
        channelID: UInt16,
        requestID: String
    ) async throws -> JSONRPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests[key] = continuation
            Task {
                do {
                    try await sendFrame(channelID: channelID, payload: payload)
                } catch {
                    await MainActor.run {
                        self.resumePendingRequest(channelID: channelID, requestID: requestID, with: .failure(error))
                    }
                }
            }
        }
    }

    private func nextRequestID(channelID: UInt16) -> RequestId {
        let next = nextRequestIDByChannel[channelID] ?? 1
        nextRequestIDByChannel[channelID] = next + 1
        return .number(next)
    }

    private func handleMessage(_ message: Message, channelID: UInt16) {
        switch message {
        case let .response(response):
            resumePendingRequest(channelID: channelID, requestID: response.id.description, with: .success(response))
        case let .notification(notification):
            handleNotification(notification, channelID: channelID)
        case let .request(request):
            handleRequest(request, channelID: channelID)
        }
    }

    private func handleRequest(_ request: JSONRPCRequest, channelID: UInt16) {
        if request.method == "request_permission" || request.method == "session/request_permission" {
            let permissionRequest: RequestPermissionRequest?
            if let params = request.params {
                do {
                    let paramsData = try JSONEncoder().encode(params)
                    permissionRequest = try JSONDecoder().decode(RequestPermissionRequest.self, from: paramsData)
                } catch {
                    permissionRequest = nil
                }
            } else {
                permissionRequest = nil
            }

            let allowOptionID = permissionRequest?.options?.first(where: { $0.kind.localizedCaseInsensitiveContains("allow") })?.optionId
                ?? permissionRequest?.options?.first?.optionId
                ?? "allow"
            let response = RequestPermissionResponse(outcome: PermissionOutcome(optionId: allowOptionID))
            Task {
                do {
                    try await sendRPCResponse(id: request.id, result: response, channelID: channelID)
                } catch {
                    Logger.agent.error("Failed to send request_permission response on channel \(channelID): \(error)")
                }
            }
            return
        }

        Task {
            do {
                try await sendRPCMethodNotFound(id: request.id, method: request.method, channelID: channelID)
            } catch {
                Logger.agent.error("Failed to send unknown method error on channel \(channelID): \(error)")
            }
        }
    }

    private func sendRPCMethodNotFound(id: RequestId, method: String, channelID: UInt16) async throws {
        let response = JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: -32601, message: "Method not found: \(method)", data: nil)
        )
        let payload = try JSONEncoder().encode(response)
        try await sendFrame(channelID: channelID, payload: payload)
    }

    private func sendRPCResponse<ResultPayload: Encodable>(id: RequestId, result: ResultPayload, channelID: UInt16) async throws {
        let resultData = try JSONEncoder().encode(result)
        let resultValue = try JSONDecoder().decode(AnyCodable.self, from: resultData)
        let response = JSONRPCResponse(id: id, result: resultValue, error: nil)
        let payload = try JSONEncoder().encode(response)
        try await sendFrame(channelID: channelID, payload: payload)
    }

    private func handleNotification(_ notification: JSONRPCNotification, channelID: UInt16) {
        guard
            notification.method == "session/update",
            let params = notification.params,
            let context = channelsByID[channelID]
        else {
            return
        }

        do {
            let data = try JSONEncoder().encode(params)
            let update = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)
            guard update.sessionId.value == context.sessionID else {
                return
            }
            context.onUpdate(update)
        } catch {
            Logger.agent.error("Failed to decode session/update on channel \(channelID): \(error)")
        }
    }

    private func resumePendingRequest(channelID: UInt16, requestID: String, with result: Result<JSONRPCResponse, Error>) {
        let key = PendingRequestKey(channelID: channelID, requestID: requestID)
        guard let continuation = pendingRequests.removeValue(forKey: key) else {
            return
        }

        switch result {
        case let .success(response):
            continuation.resume(returning: response)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func markAllChannelsDisconnected() {
        let channelIDs = Array(channelsByID.keys)
        for channelID in channelIDs {
            cleanupChannel(channelID: channelID, pendingError: AgentSessionManagerError.channelDisconnected(channelID))
        }
    }

    private func cleanupChannel(channelID: UInt16, pendingError: Error) {
        channelsByID.removeValue(forKey: channelID)
        incomingBuffers.removeValue(forKey: channelID)
        nextRequestIDByChannel.removeValue(forKey: channelID)

        let pendingKeys = pendingRequests.keys.filter { $0.channelID == channelID }
        for key in pendingKeys {
            pendingRequests.removeValue(forKey: key)?.resume(throwing: pendingError)
        }
    }

    private func isManagedConnection(_ connection: any ConnectionManaging) -> Bool {
        ObjectIdentifier(connection as AnyObject) == managedConnectionID
    }
}
