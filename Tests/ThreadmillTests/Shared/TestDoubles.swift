import Foundation
import GhosttyKit
import XCTest
@testable import Threadmill

enum TestError: Error {
    case missingStub
    case forcedFailure
}

struct RecordedRequest {
    let method: String
    let params: [String: Any]?
}

@MainActor
final class MockDaemonConnection: ConnectionManaging {
    var state: ConnectionStatus
    var debugSnapshot: ConnectionDebugSnapshot {
        ConnectionDebugSnapshot(
            status: state.label,
            sessionReady: sessionReady,
            reconnectAttempt: reconnectAttempt,
            lastErrorDescription: lastErrorDescription
        )
    }
    var onStateChange: ((ConnectionStatus) -> Void)?
    var onConnected: (() -> Void)?
    var onEvent: ((String, [String: Any]?) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var sessionReady = true
    var reconnectAttempt = 0
    var lastErrorDescription: String?
    var requests: [RecordedRequest] = []
    var sentBinaryFrames: [Data] = []
    var requestHandler: ((String, [String: Any]?, TimeInterval) throws -> Any)?
    private var binaryFrameHandler: ((Data) -> Void)?

    init(state: ConnectionStatus = .disconnected) {
        self.state = state
    }

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any {
        requests.append(RecordedRequest(method: method, params: params))
        if let requestHandler {
            return try requestHandler(method, params, timeout)
        }
        throw TestError.missingStub
    }

    func sendBinaryFrame(_ data: Data) async throws {
        sentBinaryFrames.append(data)
        binaryFrameHandler?(data)
    }

    func setBinaryFrameHandler(_ handler: ((Data) -> Void)?) {
        binaryFrameHandler = handler
    }
}

@MainActor
final class MockSurfaceHost: SurfaceHosting {
    func createSurface(in _: GhosttyNSView, socketPath _: String) -> ghostty_surface_t? {
        nil
    }

    func freeSurface(_: ghostty_surface_t?) {}
}

@MainActor
final class MockAgentManager: AgentManaging {
    var startedAgents: [(projectID: String, agentName: String)] = []
    var stoppedChannelIDs: [UInt16] = []
    var startResult: Result<UInt16, Error> = .failure(TestError.missingStub)
    var stopResult: Result<Void, Error> = .success(())

    func startAgent(projectID: String, agentName: String) async throws -> UInt16 {
        startedAgents.append((projectID, agentName))
        return try startResult.get()
    }

    func stopAgent(channelID: UInt16) async throws {
        stoppedChannelIDs.append(channelID)
        _ = try stopResult.get()
    }
}

@MainActor
final class MockSyncService: SyncServicing {
    var syncCount = 0
    var syncHandler: (() async -> Void)?

    func syncFromDaemon() async {
        syncCount += 1
        await syncHandler?()
    }
}

@MainActor
final class MockDatabaseManager: DatabaseManaging {
    var remotes: [Remote] = []
    var repos: [Repo] = []
    var projects: [Project] = []
    var threads: [ThreadModel] = []
    var conversations: [ChatConversation] = []
    var browserSessions: [BrowserSession] = []
    var updateStatusResult = true
    var updatedStatuses: [(threadID: String, status: ThreadStatus)] = []
    var replaceAllFromDaemonRemoteIDs: [String] = []
    private(set) var linkedProjects: [(projectID: String, repoID: String, remoteID: String)] = []

    func allProjects() throws -> [Project] {
        projects
    }

    func allThreads() throws -> [ThreadModel] {
        threads
    }

    func allRemotes() throws -> [Remote] {
        remotes
    }

    func allRepos() throws -> [Repo] {
        repos
    }

    func remote(id: String) throws -> Remote? {
        remotes.first(where: { $0.id == id })
    }

    func repo(id: String) throws -> Repo? {
        repos.first(where: { $0.id == id })
    }

    func saveRemote(_ remote: Remote) throws {
        if let index = remotes.firstIndex(where: { $0.id == remote.id }) {
            remotes[index] = remote
        } else {
            remotes.append(remote)
        }
    }

    func ensureDefaultRemoteExists() throws -> Remote {
        if let currentDefault = remotes.first(where: \.isDefault) {
            return currentDefault
        }

        if let beastIndex = remotes.firstIndex(where: { $0.name == DatabaseManager.RemoteDefaults.beastName }) {
            remotes[beastIndex].isDefault = true
            return remotes[beastIndex]
        }

        if let firstRemote = remotes.first {
            var updatedFirstRemote = firstRemote
            updatedFirstRemote.isDefault = true
            remotes[0] = updatedFirstRemote
            return updatedFirstRemote
        }

        let defaultRemote = Remote(
            id: UUID().uuidString,
            name: DatabaseManager.RemoteDefaults.beastName,
            host: DatabaseManager.RemoteDefaults.beastHost,
            daemonPort: DatabaseManager.RemoteDefaults.beastDaemonPort,
            useSSHTunnel: DatabaseManager.RemoteDefaults.beastUseSSHTunnel,
            cloneRoot: DatabaseManager.RemoteDefaults.beastCloneRoot,
            isDefault: true
        )
        remotes = [defaultRemote]
        return defaultRemote
    }

    func deleteRemote(id: String) throws {
        remotes.removeAll { $0.id == id }
    }

    func saveRepo(_ repo: Repo) throws {
        if let index = repos.firstIndex(where: { $0.id == repo.id }) {
            repos[index] = repo
        } else {
            repos.append(repo)
        }
    }

    func deleteRepo(id: String) throws {
        repos.removeAll { $0.id == id }
    }

    func replaceAllRepos(_ repos: [Repo]) throws {
        self.repos = repos
    }

    func replaceAllFromDaemon(projects: [Project], threads: [ThreadModel], remoteId: String) throws {
        self.projects = projects
        self.threads = threads
        replaceAllFromDaemonRemoteIDs.append(remoteId)
    }

    func updateThreadStatus(threadID: String, status: ThreadStatus) throws -> Bool {
        updatedStatuses.append((threadID, status))
        return updateStatusResult
    }

    func linkProject(projectID: String, repoID: String, remoteID: String) throws -> Bool {
        linkedProjects.append((projectID, repoID, remoteID))
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            return false
        }
        projects[index].repoId = repoID
        projects[index].remoteId = remoteID
        return true
    }

    func saveConversation(_ conversation: ChatConversation) throws {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    func conversation(id: String) throws -> ChatConversation? {
        conversations.first(where: { $0.id == id })
    }

    func listConversations(threadID: String) throws -> [ChatConversation] {
        conversations
            .filter { $0.threadID == threadID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func activeConversations(threadID: String) throws -> [ChatConversation] {
        conversations
            .filter { $0.threadID == threadID && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveBrowserSession(_ session: BrowserSession) throws {
        if let index = browserSessions.firstIndex(where: { $0.id == session.id }) {
            browserSessions[index] = session
        } else {
            browserSessions.append(session)
        }
    }

    func deleteBrowserSession(id: String) throws {
        browserSessions.removeAll { $0.id == id }
    }

    func listBrowserSessions(threadID: String) throws -> [BrowserSession] {
        browserSessions
            .filter { $0.threadID == threadID }
            .sorted {
                if $0.order == $1.order {
                    return $0.createdAt < $1.createdAt
                }
                return $0.order < $1.order
            }
    }
}

@MainActor
final class MockChatConversationService: ChatConversationManaging {
    var createConversationResult: Result<ChatConversation, Error> = .failure(TestError.missingStub)
    var listConversationsResult: Result<[ChatConversation], Error> = .success([])
    var activeConversationsResult: Result<[ChatConversation], Error> = .success([])
    var archiveConversationResult: Result<Void, Error> = .success(())
    var updateTitleResult: Result<Void, Error> = .success(())
    var verifySessionResult: Result<Bool, Error> = .success(true)

    private(set) var createdConversations: [(threadID: String, directory: String, agentType: String)] = []
    private(set) var listedThreadIDs: [String] = []
    private(set) var activeThreadIDs: [String] = []
    private(set) var archivedConversationIDs: [String] = []
    private(set) var updatedTitles: [(id: String, title: String)] = []
    private(set) var verifiedConversationIDs: [String] = []

    func createConversation(threadID: String, directory: String, agentType: String) async throws -> ChatConversation {
        createdConversations.append((threadID, directory, agentType))
        return try createConversationResult.get()
    }

    func listConversations(threadID: String) async throws -> [ChatConversation] {
        listedThreadIDs.append(threadID)
        return try listConversationsResult.get()
    }

    func activeConversations(threadID: String) async throws -> [ChatConversation] {
        activeThreadIDs.append(threadID)
        return try activeConversationsResult.get()
    }

    func archiveConversation(id: String) async throws {
        archivedConversationIDs.append(id)
        _ = try archiveConversationResult.get()
    }

    func updateTitle(conversationID: String, title: String) async throws {
        updatedTitles.append((conversationID, title))
        _ = try updateTitleResult.get()
    }

    func verifySession(conversation: ChatConversation) async throws -> Bool {
        verifiedConversationIDs.append(conversation.id)
        return try verifySessionResult.get()
    }
}

@MainActor
final class MockTerminalMultiplexer: TerminalMultiplexing {
    var detachedByThreadPreset: [(threadID: String, preset: String)] = []
    var detachedChannels: [UInt16] = []
    var attachCallCount = 0
    var attachHandler: ((String, String, String) async throws -> RelayEndpoint)?

    func endpoint(threadID _: String, sessionID _: String) -> RelayEndpoint? {
        nil
    }

    func attach(threadID: String, sessionID: String, preset: String) async throws -> RelayEndpoint {
        attachCallCount += 1
        if let attachHandler {
            return try await attachHandler(threadID, sessionID, preset)
        }
        throw TestError.missingStub
    }

    func detach(channelID: UInt16) {
        detachedChannels.append(channelID)
    }

    func detach(threadID: String, sessionID: String) {
        detachedByThreadPreset.append((threadID, sessionID))
    }

    func detachAll() {}

    func handleBinaryFrame(_: Data) {}

    func reattachAll() async {}
}

@MainActor
final class MockRemoteConnectionPool: RemoteConnectionPooling {
    var connections: [String: any ConnectionManaging] = [:]
    var addedRemotes: [Remote] = []
    var updatedRemotes: [Remote] = []
    var removedRemoteIDs: [String] = []
    private(set) var ensuredRemoteIDs: [String] = []
    private(set) var activatedRemoteIDs: [String] = []
    var activeRemoteId: String?

    func connection(for remoteId: String) -> (any ConnectionManaging)? {
        connections[remoteId]
    }

    func activate(remoteId: String) throws {
        guard connections[remoteId] != nil else {
            throw RemoteConnectionPoolError.unknownRemote(id: remoteId)
        }

        activatedRemoteIDs.append(remoteId)
        activeRemoteId = remoteId
    }

    func addRemote(_ remote: Remote) {
        addedRemotes.append(remote)
        if connections[remote.id] == nil {
            connections[remote.id] = MockDaemonConnection(state: .disconnected)
        }
    }

    func removeRemote(id: String) {
        removedRemoteIDs.append(id)
        if let connection = connections.removeValue(forKey: id) {
            connection.stop()
        }
        if activeRemoteId == id {
            activeRemoteId = nil
        }
    }

    func updateRemote(_ remote: Remote) {
        updatedRemotes.append(remote)
        if connections[remote.id] == nil {
            connections[remote.id] = MockDaemonConnection(state: .disconnected)
        }
    }

    func ensureConnected(remoteId: String) async throws {
        guard let connection = connections[remoteId] else {
            throw RemoteConnectionPoolError.unknownRemote(id: remoteId)
        }

        ensuredRemoteIDs.append(remoteId)
        guard connection.state == .disconnected else {
            return
        }
        connection.start()
    }

    func stopAll() {
        for connection in connections.values {
            connection.stop()
        }
    }
}

@MainActor
func makeSingleRemoteConnectionPool(
    connection: any ConnectionManaging,
    remoteID: String = "remote-1"
) -> MockRemoteConnectionPool {
    let pool = MockRemoteConnectionPool()
    pool.connections[remoteID] = connection
    pool.activeRemoteId = remoteID
    return pool
}

@MainActor
final class MockTunnelManager: TunnelManaging {
    var onExit: ((Int32) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var startResults: [Result<Void, Error>] = []

    func enqueueStartResult(_ result: Result<Void, Error>) {
        startResults.append(result)
    }

    func start() async throws {
        startCallCount += 1
        if !startResults.isEmpty {
            let next = startResults.removeFirst()
            switch next {
            case .success:
                return
            case let .failure(error):
                throw error
            }
        }
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
final class MockWebSocketClient: WebSocketManaging {
    var onEvent: ((String, [String: Any]?) -> Void)?
    var onBinaryMessage: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    var connectURLs: [URL] = []
    var disconnectCallCount = 0
    var sentRequests: [RecordedRequest] = []
    var sentBinaryFrames: [Data] = []

    var requestHandler: ((String, [String: Any]?, TimeInterval) throws -> Any)?

    func connect(to url: URL) {
        connectURLs.append(url)
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func sendRequest(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any {
        sentRequests.append(RecordedRequest(method: method, params: params))
        if let requestHandler {
            return try requestHandler(method, params, timeout)
        }
        throw TestError.missingStub
    }

    func sendBinaryFrame(_ data: Data) async throws {
        sentBinaryFrames.append(data)
    }

    func emitEvent(method: String, params: [String: Any]?) {
        onEvent?(method, params)
    }

    func emitBinaryMessage(_ data: Data) {
        onBinaryMessage?(data)
    }

    func emitDisconnect(_ error: Error?) {
        onDisconnect?(error)
    }
}

@MainActor
func waitForCondition(timeout: TimeInterval = 1.0, pollNanoseconds: UInt64 = 10_000_000, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
}

func makeFrame(channelID: UInt16, payload: [UInt8]) -> Data {
    var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
    frame.append(contentsOf: payload)
    return frame
}


