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
        }
    }
}

@MainActor
@Observable
final class AgentSessionManager {
    private struct SessionContext: Hashable {
        let id: String
        let threadID: String
        let channelID: UInt16
        let agentConfig: AgentConfig
        var acpSessionID: String
    }

    private struct PendingRequestKey: Hashable {
        let channelID: UInt16
        let requestID: String
    }

    private let agentManager: any AgentManaging
    private let connectionManager: any ConnectionManaging
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

        try await agentManager.stopAgent(channelID: existing.channelID)
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
        let channelID = try await agentManager.startAgent(projectID: projectID, agentName: agentConfig.name)
        let sessionID = sessionIDOverride ?? UUID().uuidString
        var context = SessionContext(
            id: sessionID,
            threadID: threadID,
            channelID: channelID,
            agentConfig: agentConfig,
            acpSessionID: sessionID
        )

        sessionsByID[sessionID] = context
        sessionIDByChannel[channelID] = sessionID
        incomingBuffers[channelID] = Data()
        updatesBySessionID[sessionID] = []

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
            params: NewSessionRequest(cwd: agentConfig.cwd ?? "."),
            channelID: channelID,
            timeout: 20
        )
        context.acpSessionID = newSession.sessionId.value
        sessionsByID[sessionID] = context

        return sessionID
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

        let _: SessionPromptResponse = try await sendRequest(
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(context.acpSessionID),
                prompt: [.text(TextContent(text: text))]
            ),
            channelID: context.channelID,
            timeout: 120
        )
    }

    func cancelPrompt(sessionID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        try await sendNotification(
            method: "session/cancel",
            params: CancelSessionRequest(sessionId: SessionId(context.acpSessionID)),
            channelID: context.channelID
        )
    }

    func setMode(sessionID: String, modeID: String) async throws {
        guard let context = sessionsByID[sessionID] else {
            throw AgentSessionManagerError.unknownSession(sessionID)
        }

        let _: SetModeResponse = try await sendRequest(
            method: "session/set_mode",
            params: SetModeRequest(sessionId: SessionId(context.acpSessionID), modeId: modeID),
            channelID: context.channelID,
            timeout: 20
        )
    }

    func handleBinaryFrame(_ frame: Data) {
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
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await MainActor.run {
                self?.resumePendingRequest(channelID: channelID, requestID: requestIDString, with: .failure(AgentSessionManagerError.requestTimedOut))
            }
        }

        defer { timeoutTask.cancel() }

        let response = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[key] = continuation
            Task {
                do {
                    try await sendFrame(payload, channelID: channelID)
                } catch {
                    await MainActor.run {
                        self.resumePendingRequest(channelID: channelID, requestID: requestIDString, with: .failure(error))
                    }
                }
            }
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
        case .request:
            break
        }
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

        sessionIDByChannel.removeValue(forKey: context.channelID)
        incomingBuffers.removeValue(forKey: context.channelID)
        nextRequestIDByChannel.removeValue(forKey: context.channelID)
        updatesBySessionID.removeValue(forKey: sessionID)

        let pendingKeys = pendingRequests.keys.filter { $0.channelID == context.channelID }
        for key in pendingKeys {
            pendingRequests.removeValue(forKey: key)?.resume(throwing: AgentSessionManagerError.unknownSession(sessionID))
        }
    }
}
