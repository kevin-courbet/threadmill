import ACPModel
import Foundation
import Observation

enum AgentSessionManagerError: LocalizedError {
    case unknownThread(String)
    case unknownSession(String)
    case unknownChannel(UInt16)
    case invalidBinaryFrame
    case rpcError(String)
    case requestTimedOut
    case sessionDisconnected(String)

    var errorDescription: String? {
        switch self {
        case let .unknownThread(threadID):
            return "Unable to resolve project for thread \(threadID)."
        case let .unknownSession(sessionID):
            return "Unknown agent session: \(sessionID)."
        case let .unknownChannel(channelID):
            return "Unknown agent channel: \(channelID)."
        case .invalidBinaryFrame:
            return "Invalid binary frame."
        case let .rpcError(message):
            return message
        case .requestTimedOut:
            return "Agent RPC timed out."
        case let .sessionDisconnected(sessionID):
            return "Agent session is disconnected: \(sessionID)."
        }
    }
}

@MainActor
@Observable
final class AgentSessionManager {
    private struct SessionContext: Hashable {
        let id: String
        let threadID: String
        var channelID: UInt16?
        let agentConfig: AgentConfig
        var acpSessionID: String
    }

    private struct PendingRequestKey: Hashable {
        let channelID: UInt16
        let requestID: String
    }

    private let agentManager: any AgentManaging
    private let connectionManager: any ConnectionManaging
    private let managedConnectionID: ObjectIdentifier
    private let projectIDResolver: @MainActor (String) -> String?

    private var sessionsByID: [String: SessionContext] = [:]
    private var sessionIDByChannel: [UInt16: String] = [:]
    private var incomingBuffers: [UInt16: Data] = [:]
    private var nextRequestIDByChannel: [UInt16: Int] = [:]
    private var pendingRequests: [PendingRequestKey: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    var updatesBySessionID: [String: [SessionUpdateNotification]] = [:]
    var onSessionUpdate: ((String, SessionUpdateNotification) -> Void)?

    init(
        agentManager: any AgentManaging,
        connectionManager: any ConnectionManaging,
        projectIDResolver: @escaping @MainActor (String) -> String?
    ) {
        self.agentManager = agentManager
        self.connectionManager = connectionManager
        managedConnectionID = ObjectIdentifier(connectionManager as AnyObject)
        self.projectIDResolver = projectIDResolver
    }

    @discardableResult
    func startSession(agentConfig: AgentConfig, threadID: String) async throws -> String {
        guard let projectID = projectIDResolver(threadID) else {
            throw AgentSessionManagerError.unknownThread(threadID)
        }

        return try await startSession(agentConfig: agentConfig, threadID: threadID, projectID: projectID, sessionIDOverride: nil)
    }

    @discardableResult
    func switchAgent(sessionID: String, agentConfig: AgentConfig) async throws -> String {
        guard let existing = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let projectID = projectIDResolver(existing.threadID) else {
            throw AgentSessionManagerError.unknownThread(existing.threadID)
        }

        if let channelID = existing.channelID {
            try await agentManager.stopAgent(channelID: channelID)
        }
        cleanupSession(sessionID: sessionID)

        return try await startSession(
            agentConfig: agentConfig,
            threadID: existing.threadID,
            projectID: projectID,
            sessionIDOverride: sessionID
        )
    }

    private func startSession(
        agentConfig: AgentConfig,
        threadID: String,
        projectID: String,
        sessionIDOverride: String?
    ) async throws -> String {
        let sessionID = sessionIDOverride ?? UUID().uuidString
        var context = SessionContext(
            id: sessionID,
            threadID: threadID,
            channelID: nil,
            agentConfig: agentConfig,
            acpSessionID: sessionID
        )

        sessionsByID[sessionID] = context
        if updatesBySessionID[sessionID] == nil {
            updatesBySessionID[sessionID] = []
        }

        do {
            try await attachSession(&context, projectID: projectID)
            sessionsByID[sessionID] = context
            return sessionID
        } catch {
            cleanupSession(sessionID: sessionID)
            throw error
        }
    }

    func stopSession(channelID: UInt16) async throws {
        guard let sessionID = sessionIDByChannel[channelID] else {
            throw AgentSessionManagerError.unknownChannel(channelID)
        }

        try await agentManager.stopAgent(channelID: channelID)
        cleanupSession(sessionID: sessionID)
    }

    func sendPrompt(text: String, sessionID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        let _: SessionPromptResponse = try await sendRequest(
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(context.acpSessionID),
                prompt: [.text(TextContent(text: text))]
            ),
            channelID: channelID,
            timeout: 120
        )
    }

    func cancelPrompt(sessionID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        try await sendNotification(
            method: "session/cancel",
            params: CancelSessionRequest(sessionId: SessionId(context.acpSessionID)),
            channelID: channelID
        )
    }

    func setMode(sessionID: String, modeID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        let _: SetModeResponse = try await sendRequest(
            method: "session/set_mode",
            params: SetModeRequest(sessionId: SessionId(context.acpSessionID), modeId: modeID),
            channelID: channelID,
            timeout: 20
        )
    }

    func setModel(sessionID: String, modelID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        let _: SetModelResponse = try await sendRequest(
            method: "session/set_model",
            params: SetModelRequest(sessionId: SessionId(context.acpSessionID), modelId: modelID),
            channelID: channelID,
            timeout: 20
        )
    }

    func setConfigOption(sessionID: String, key: String, value: SessionConfigOptionValue) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        let _: SetSessionConfigOptionResponse = try await sendRequest(
            method: "session/set_config_option",
            params: SetSessionConfigOptionRequest(
                sessionId: SessionId(context.acpSessionID),
                configId: SessionConfigId(key),
                value: value
            ),
            channelID: channelID,
            timeout: 20
        )
    }

    func loadSession(sessionID: String, acpSessionID: String) async throws -> LoadSessionResponse {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        return try await sendRequest(
            method: "session/load",
            params: LoadSessionRequest(sessionId: SessionId(acpSessionID)),
            channelID: channelID,
            timeout: 20
        )
    }

    func listSessions(sessionID: String) async throws -> ListSessionsResponse {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        return try await sendRequest(
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
            markAllSessionsDisconnected()
        case .connecting, .connected:
            break
        }
    }

    func handleConnectionReconnected(on connection: any ConnectionManaging) async {
        guard isManagedConnection(connection) else {
            return
        }

        let sessionIDs = sessionsByID.keys.sorted()
        for sessionID in sessionIDs {
            guard var context = sessionsByID[sessionID], context.channelID == nil else {
                continue
            }

            guard let projectID = projectIDResolver(context.threadID) else {
                NSLog("threadmill-agent: unable to reattach session %@, thread missing: %@", sessionID, context.threadID)
                continue
            }

            do {
                try await attachSession(&context, projectID: projectID)
                sessionsByID[sessionID] = context
            } catch {
                NSLog("threadmill-agent: failed to reattach session %@: %@", sessionID, "\(error)")
            }
        }
    }

    func handleBinaryFrame(_ frame: Data) {
        handleBinaryFrame(frame, from: connectionManager)
    }

    func handleBinaryFrame(_ frame: Data, from connection: any ConnectionManaging) {
        guard isManagedConnection(connection) else {
            return
        }

        guard frame.count >= 2 else {
            return
        }

        let channelID = (UInt16(frame[0]) << 8) | UInt16(frame[1])
        guard sessionIDByChannel[channelID] != nil else {
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
                NSLog("threadmill-agent: failed to decode ACP message on channel %hu: %@", channelID, "\(error)")
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
        let payload = try JSONEncoder().encode(
            JSONRPCNotification(method: method, params: paramsValue)
        )
        try await sendFrame(payload, channelID: channelID)
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
                    try await sendFrame(payload, channelID: channelID)
                } catch {
                    await MainActor.run {
                        self.resumePendingRequest(channelID: channelID, requestID: requestID, with: .failure(error))
                    }
                }
            }
        }
    }

    private func sendFrame(_ payload: Data, channelID: UInt16) async throws {
        var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
        frame.append(payload)
        frame.append(0x0A)
        try await connectionManager.sendBinaryFrame(frame)
    }

    private func nextRequestID(channelID: UInt16) -> RequestId {
        let next = (nextRequestIDByChannel[channelID] ?? 1)
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
                    NSLog("threadmill-agent: failed to send request_permission response on channel %hu: %@", channelID, "\(error)")
                }
            }
            return
        }

        if request.method == "fs/read_text_file" || request.method == "fs/write_text_file" || request.method.hasPrefix("terminal/") {
            Task {
                do {
                    try await sendRPCMethodNotFound(id: request.id, method: request.method, channelID: channelID)
                } catch {
                    NSLog("threadmill-agent: failed to send unsupported method error on channel %hu: %@", channelID, "\(error)")
                }
            }
            return
        }

        Task {
            do {
                try await sendRPCMethodNotFound(id: request.id, method: request.method, channelID: channelID)
            } catch {
                NSLog("threadmill-agent: failed to send unknown method error on channel %hu: %@", channelID, "\(error)")
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
        try await sendFrame(payload, channelID: channelID)
    }

    private func sendRPCResponse<ResultPayload: Encodable>(id: RequestId, result: ResultPayload, channelID: UInt16) async throws {
        let resultData = try JSONEncoder().encode(result)
        let resultValue = try JSONDecoder().decode(AnyCodable.self, from: resultData)
        let response = JSONRPCResponse(id: id, result: resultValue, error: nil)
        let payload = try JSONEncoder().encode(response)
        try await sendFrame(payload, channelID: channelID)
    }

    private func handleNotification(_ notification: JSONRPCNotification, channelID: UInt16) {
        guard
            notification.method == "session/update",
            let params = notification.params,
            let sessionID = sessionIDByChannel[channelID]
        else {
            return
        }

        do {
            let data = try JSONEncoder().encode(params)
            let update = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)
            updatesBySessionID[sessionID, default: []].append(update)
            onSessionUpdate?(sessionID, update)
        } catch {
            NSLog("threadmill-agent: failed to decode session/update on channel %hu: %@", channelID, "\(error)")
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

    private func cleanupSession(sessionID: String) {
        guard let context = sessionsByID.removeValue(forKey: sessionID) else {
            return
        }

        if let channelID = context.channelID {
            cleanupChannel(channelID: channelID, pendingError: AgentSessionManagerError.unknownSession(sessionID))
        }
        updatesBySessionID.removeValue(forKey: sessionID)
    }

    private func attachSession(_ context: inout SessionContext, projectID: String) async throws {
        let channelID = try await agentManager.startAgent(projectID: projectID, agentName: context.agentConfig.name)
        context.channelID = channelID
        sessionIDByChannel[channelID] = context.id
        incomingBuffers[channelID] = Data()

        do {
            let _: InitializeResponse = try await sendRequest(
                method: "initialize",
                params: InitializeRequest(
                    protocolVersion: 1,
                    clientCapabilities: ClientCapabilities(
                        fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                        terminal: false
                    ),
                    clientInfo: ClientInfo(name: "Threadmill", title: "Threadmill", version: "dev")
                ),
                channelID: channelID,
                timeout: 20
            )

            let newSession: NewSessionResponse = try await sendRequest(
                method: "session/new",
                params: NewSessionRequest(cwd: context.agentConfig.cwd ?? "."),
                channelID: channelID,
                timeout: 20
            )
            context.acpSessionID = newSession.sessionId.value
        } catch {
            cleanupChannel(channelID: channelID, pendingError: error)
            context.channelID = nil
            throw error
        }
    }

    private func markAllSessionsDisconnected() {
        let sessionIDs = sessionsByID.keys
        for sessionID in sessionIDs {
            guard var context = sessionsByID[sessionID], let channelID = context.channelID else {
                continue
            }

            cleanupChannel(channelID: channelID, pendingError: AgentSessionManagerError.sessionDisconnected(sessionID))
            context.channelID = nil
            sessionsByID[sessionID] = context
        }
    }

    private func cleanupChannel(channelID: UInt16, pendingError: Error) {
        sessionIDByChannel.removeValue(forKey: channelID)
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
