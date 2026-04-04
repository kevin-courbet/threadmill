import ACPModel
import Foundation
import Observation
import os

struct PendingPermissionRequest: Identifiable {
    let id: String
    let sessionID: String
    let channelID: UInt16
    let requestID: RequestId
    /// Human-readable summary of what the permission is for (e.g., "Read /etc/passwd")
    let title: String
    /// Detailed description from the agent's message field
    let message: String
    let options: [(id: String, label: String)]
    let timestamp: Date
}

enum AgentSessionManagerError: LocalizedError {
    case unknownSession(String)
    case unknownChannel(UInt16)
    case invalidBinaryFrame
    case rpcError(String)
    case requestTimedOut
    case sessionDisconnected(String)
    case chatStartFailed(String)
    case chatAttachFailed(String)

    var errorDescription: String? {
        switch self {
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
        case let .chatStartFailed(message):
            return "chat.start failed: \(message)"
        case let .chatAttachFailed(message):
            return "chat.attach failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class AgentSessionManager: ChatManaging {
    struct SessionCapabilities {
        var availableModes: [ModeInfo]
        var currentModeID: String?
        var availableModels: [ModelInfo]
        var currentModelID: String?

        static let empty = SessionCapabilities(
            availableModes: [],
            currentModeID: nil,
            availableModels: [],
            currentModelID: nil
        )
    }

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

    private let connectionManager: any ConnectionManaging
    private let managedConnectionID: ObjectIdentifier

    private var sessionsByID: [String: SessionContext] = [:]
    private var sessionCapabilitiesByID: [String: SessionCapabilities] = [:]
    private var sessionIDByChannel: [UInt16: String] = [:]
    private var incomingBuffers: [UInt16: Data] = [:]
    private var nextRequestIDByChannel: [UInt16: Int] = [:]
    private var pendingRequests: [PendingRequestKey: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    var updatesBySessionID: [String: [SessionUpdateNotification]] = [:]
    var onSessionUpdate: ((String, SessionUpdateNotification) -> Void)?

    // Permission handling — pendingPermissionRequests is observable so any view can
    // read cross-session permissions without a single-owner callback.
    var permissionMode: PermissionMode = .fullAccess
    private(set) var pendingPermissionRequests: [String: PendingPermissionRequest] = [:]

    /// Session failure errors received from Spindle's chat.session_failed event.
    /// Keyed by session ID. Observable so VMs can react immediately.
    private(set) var sessionFailures: [String: String] = [:]

    init(
        connectionManager: any ConnectionManaging
    ) {
        self.connectionManager = connectionManager
        managedConnectionID = ObjectIdentifier(connectionManager as AnyObject)
    }

    @discardableResult
    func startSession(agentConfig: AgentConfig, threadID: String) async throws -> String {
        let sessionID = try await chatStart(threadID: threadID, agentName: agentConfig.name)

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
            try await attachSession(&context)
            sessionsByID[sessionID] = context
            return sessionID
        } catch {
            cleanupSession(sessionID: sessionID)
            throw error
        }
    }

    @discardableResult
    func restoreSession(sessionID: String?, agentConfig: AgentConfig, threadID: String) async throws -> String {
        if let sessionID {
            if hasSession(sessionID: sessionID) {
                return sessionID
            }

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
                try await attachSession(&context)
                sessionsByID[sessionID] = context
                return sessionID
            } catch {
                cleanupSession(sessionID: sessionID)
                Logger.agent.error("Failed to restore session \(sessionID, privacy: .public); starting replacement: \(error.localizedDescription, privacy: .public)")
            }
        }

        return try await startSession(agentConfig: agentConfig, threadID: threadID)
    }

    @discardableResult
    func switchAgent(sessionID: String, agentConfig: AgentConfig) async throws -> String {
        guard let existing = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        try await chatStop(threadID: existing.threadID, sessionID: sessionID)
        cleanupSession(sessionID: sessionID)

        return try await startSession(agentConfig: agentConfig, threadID: existing.threadID)
    }

    func stopSession(sessionID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        try await chatStop(threadID: context.threadID, sessionID: sessionID)
        cleanupSession(sessionID: sessionID)
    }

    func sendPrompt(text: String, sessionID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        guard let channelID = context.channelID else {
            throw AgentSessionManagerError.sessionDisconnected(sessionID)
        }

        Logger.agent.error("sendPrompt RPC — acpSessionID=\(context.acpSessionID, privacy: .public), channelID=\(channelID, privacy: .public), textLength=\(text.count, privacy: .public)")
        let response: SessionPromptResponse = try await sendRequest(
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(context.acpSessionID),
                prompt: [.text(TextContent(text: text))]
            ),
            channelID: channelID,
            timeout: 120
        )
        Logger.agent.error("sendPrompt response — stopReason=\(String(describing: response.stopReason), privacy: .public)")
    }

    func hasSession(sessionID: String) -> Bool {
        sessionsByID[sessionID] != nil
    }

    func capabilities(for sessionID: String) -> SessionCapabilities {
        sessionCapabilitiesByID[sessionID] ?? .empty
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

        var capabilities = sessionCapabilitiesByID[sessionID] ?? .empty
        capabilities.currentModeID = modeID
        sessionCapabilitiesByID[sessionID] = capabilities
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

        var capabilities = sessionCapabilitiesByID[sessionID] ?? .empty
        capabilities.currentModelID = modelID
        sessionCapabilitiesByID[sessionID] = capabilities
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

            do {
                try await attachSession(&context)
                sessionsByID[sessionID] = context
            } catch {
                Logger.agent.error("Failed to reattach session \(sessionID): \(error)")
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
                Logger.agent.error("Failed to decode ACP message on channel \(channelID): \(error)")
            }
        }

        incomingBuffers[channelID] = buffer
    }

    // MARK: - Chat RPCs

    func chatHistory(threadID: String, sessionID: String, cursor: UInt64? = nil) async throws -> ChatHistoryResponse {
        var params: [String: Any] = [
            "thread_id": threadID,
            "session_id": sessionID,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        let result = try await connectionManager.request(
            method: "chat.history",
            params: params,
            timeout: 20
        )

        return try decodeChatResponse(result, context: "chat.history")
    }

    func chatList(threadID: String) async throws -> [ChatSessionInfo] {
        let result = try await connectionManager.request(
            method: "chat.list",
            params: ["thread_id": threadID],
            timeout: 20
        )

        return try decodeChatResponse(result, context: "chat.list")
    }

    private func chatStart(threadID: String, agentName: String) async throws -> String {
        let result = try await connectionManager.request(
            method: "chat.start",
            params: [
                "thread_id": threadID,
                "agent_name": agentName,
            ],
            timeout: 20
        )

        guard
            let payload = result as? [String: Any],
            let sessionID = payload["session_id"] as? String
        else {
            throw AgentSessionManagerError.chatStartFailed("invalid response")
        }

        return sessionID
    }

    private func chatAttach(threadID: String, sessionID: String) async throws -> (channelID: UInt16, acpSessionID: String, modes: Any?, models: Any?, configOptions: Any?) {
        let result = try await connectionManager.request(
            method: "chat.attach",
            params: [
                "thread_id": threadID,
                "session_id": sessionID,
            ],
            timeout: 40
        )

        guard
            let payload = result as? [String: Any],
            let channelID = payload["channel_id"] as? Int,
            channelID > 0,
            channelID <= Int(UInt16.max),
            let acpSessionID = payload["acp_session_id"] as? String
        else {
            throw AgentSessionManagerError.chatAttachFailed("invalid response")
        }

        return (UInt16(channelID), acpSessionID, payload["modes"], payload["models"], payload["config_options"])
    }

    private func chatStop(threadID: String, sessionID: String) async throws {
        _ = try await connectionManager.request(
            method: "chat.stop",
            params: [
                "thread_id": threadID,
                "session_id": sessionID,
            ],
            timeout: 10
        )
    }

    private func decodeChatResponse<Payload: Decodable>(_ result: Any, context: String) throws -> Payload {
        guard JSONSerialization.isValidJSONObject(result) else {
            throw AgentSessionManagerError.rpcError("\(context) returned invalid JSON payload")
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AgentSessionManagerError.rpcError("\(context) decode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - ACP Frame Transport

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

    // MARK: - ACP Message Handling

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

            if permissionMode == .fullAccess {
                // Auto-approve
                let response = RequestPermissionResponse(outcome: PermissionOutcome(optionId: allowOptionID))
                Task {
                    do {
                        try await sendRPCResponse(id: request.id, result: response, channelID: channelID)
                    } catch {
                        Logger.agent.error("Failed to send request_permission response on channel \(channelID): \(error)")
                    }
                }
            } else {
                // Surface to user
                guard let sessionID = sessionIDByChannel[channelID] else {
                    Logger.agent.error("Permission request on channel \(channelID) with no mapped session — this is a bug")
                    return
                }
                let title = Self.permissionTitle(from: permissionRequest)
                let pending = PendingPermissionRequest(
                    id: UUID().uuidString,
                    sessionID: sessionID,
                    channelID: channelID,
                    requestID: request.id,
                    title: title,
                    message: permissionRequest?.message ?? "",
                    options: permissionRequest?.options?.map { ($0.optionId, $0.name) } ?? [
                        (allowOptionID, "Allow"),
                        ("deny", "Deny"),
                    ],
                    timestamp: Date()
                )
                pendingPermissionRequests[pending.id] = pending
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

    /// Extract a human-readable title from the permission request's toolCall rawInput.
    /// Recognizes file paths, commands, plans, and falls back to the message or method name.
    private static func permissionTitle(from request: RequestPermissionRequest?) -> String {
        guard let request else { return "Permission requested" }

        // Try extracting structured info from rawInput
        if let rawInput = request.toolCall?.rawInput?.value as? [String: Any] {
            if let filePath = rawInput["file_path"] as? String ?? rawInput["filePath"] as? String ?? rawInput["path"] as? String {
                return "Read \(filePath)"
            }
            if let command = rawInput["command"] as? String ?? rawInput["cmd"] as? String {
                let truncated = command.count > 80 ? String(command.prefix(77)) + "..." : command
                return "Run: \(truncated)"
            }
            if rawInput["plan"] as? String != nil {
                return "Execute plan"
            }
        }

        // Fall back to message, then method
        if let message = request.message, !message.isEmpty {
            return message
        }
        return "Permission requested"
    }

    func recordSessionFailure(sessionID: String, error: String) {
        sessionFailures[sessionID] = error
    }

    func respondToPermissionRequest(id: String, optionId: String) async {
        guard let pending = pendingPermissionRequests.removeValue(forKey: id) else {
            Logger.agent.warning("Permission request \(id) not found — already resolved or expired")
            return
        }
        let response = RequestPermissionResponse(outcome: PermissionOutcome(optionId: optionId))
        do {
            try await sendRPCResponse(id: pending.requestID, result: response, channelID: pending.channelID)
        } catch {
            Logger.agent.error("Failed to send permission response for \(id): \(error)")
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
            if case let .currentModeUpdate(modeID) = update.update {
                var capabilities = sessionCapabilitiesByID[sessionID] ?? .empty
                capabilities.currentModeID = modeID
                sessionCapabilitiesByID[sessionID] = capabilities
            }
            onSessionUpdate?(sessionID, update)
        } catch {
            Logger.agent.error("Failed to decode session/update on channel \(channelID): \(error)")
        }
    }

    // MARK: - Session Lifecycle

    private func attachSession(_ context: inout SessionContext) async throws {
        let attach = try await chatAttach(threadID: context.threadID, sessionID: context.id)
        let channelID = attach.channelID
        context.channelID = channelID
        context.acpSessionID = context.id
        sessionIDByChannel[channelID] = context.id
        incomingBuffers[channelID] = Data()

        let capabilities = parseCapabilities(modes: attach.modes, models: attach.models, configOptions: attach.configOptions)
        sessionCapabilitiesByID[context.id] = capabilities
    }

    private func parseCapabilities(modes: Any?, models: Any?, configOptions: Any? = nil) -> SessionCapabilities {
        var caps = SessionCapabilities.empty

        if let modesDict = modes as? [String: Any] {
            if let currentModeID = modesDict["currentModeId"] as? String {
                caps.currentModeID = currentModeID
            }
            if let availableModes = modesDict["availableModes"] as? [[String: Any]] {
                caps.availableModes = availableModes.compactMap { dict in
                    guard let id = dict["id"] as? String, let name = dict["name"] as? String else {
                        return nil
                    }
                    return ModeInfo(id: id, name: name)
                }
            }
        }

        if let modelsDict = models as? [String: Any] {
            if let currentModelID = modelsDict["currentModelId"] as? String {
                caps.currentModelID = currentModelID
            }
            if let availableModels = modelsDict["availableModels"] as? [[String: Any]] {
                caps.availableModels = availableModels.compactMap { dict in
                    guard let modelId = dict["modelId"] as? String, let name = dict["name"] as? String else {
                        return nil
                    }
                    return ModelInfo(modelId: modelId, name: name)
                }
            }
        }

        if let configOptionsArray = configOptions as? [[String: Any]] {
            do {
                let data = try JSONSerialization.data(withJSONObject: configOptionsArray)
                let options = try JSONDecoder().decode([SessionConfigOption].self, from: data)
                for option in options where option.id.value == "model" {
                    if case let .select(select) = option.kind {
                        let allOptions: [SessionConfigSelectOption]
                        switch select.options {
                        case let .ungrouped(options):
                            allOptions = options
                        case let .grouped(groups):
                            allOptions = groups.flatMap(\.options)
                        }
                        caps.availableModels = allOptions.map { selectOption in
                            ModelInfo(modelId: selectOption.value.value, name: selectOption.name)
                        }
                        caps.currentModelID = select.currentValue.value
                    }
                }
            } catch {
                Logger.agent.error("Failed to parse config_options from chat.attach: \(error)")
            }
        }

        return caps
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
        sessionCapabilitiesByID.removeValue(forKey: sessionID)
        updatesBySessionID.removeValue(forKey: sessionID)
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
