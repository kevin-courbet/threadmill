import Foundation
import GhosttyKit

struct FileBrowserEntry: Identifiable, Hashable, Codable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64

    var id: String { path }
}

struct FileReadPayload: Codable {
    let content: String
    let size: UInt64
}

@MainActor
protocol FileBrowsing: AnyObject {
    func listDirectory(path: String) async throws -> [FileBrowserEntry]
    func readFile(path: String) async throws -> FileReadPayload
}

@MainActor
protocol ConnectionManaging: AnyObject {
    var state: ConnectionStatus { get }
    func start()
    func stop()
    func request(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any
    func sendBinaryFrame(_ data: Data) async throws
}

@MainActor
protocol DatabaseManaging: AnyObject {
    func allProjects() throws -> [Project]
    func allThreads() throws -> [ThreadModel]
    func replaceAllFromDaemon(projects: [Project], threads: [ThreadModel]) throws
    func updateThreadStatus(threadID: String, status: ThreadStatus) throws -> Bool
    func saveConversation(_ conversation: ChatConversation) throws
    func conversation(id: String) throws -> ChatConversation?
    func listConversations(threadID: String) throws -> [ChatConversation]
    func activeConversations(threadID: String) throws -> [ChatConversation]
    func saveBrowserSession(_ session: BrowserSession) throws
    func deleteBrowserSession(id: String) throws
    func listBrowserSessions(threadID: String) throws -> [BrowserSession]
}

@MainActor
protocol ChatConversationManaging: AnyObject {
    func createConversation(threadID: String, directory: String) async throws -> ChatConversation
    func listConversations(threadID: String) async throws -> [ChatConversation]
    func activeConversations(threadID: String) async throws -> [ChatConversation]
    func archiveConversation(id: String) async throws
    func updateTitle(conversationID: String, title: String) async throws
    func verifySession(conversation: ChatConversation) async throws -> Bool
}

@MainActor
protocol SyncServicing: AnyObject {
    func syncFromDaemon() async
}

@MainActor
protocol TerminalMultiplexing: AnyObject {
    func endpoint(threadID: String, preset: String) -> RelayEndpoint?
    func attach(threadID: String, preset: String) async throws -> RelayEndpoint
    func detach(channelID: UInt16)
    func detach(threadID: String, preset: String)
    func detachAll()
    func handleBinaryFrame(_ data: Data)
    func reattachAll() async
}

@MainActor
protocol SurfaceHosting: AnyObject {
    func createSurface(in view: GhosttyNSView, socketPath: String) -> ghostty_surface_t?
    func freeSurface(_ surface: ghostty_surface_t?)
}

@MainActor
protocol TunnelManaging: AnyObject {
    var onExit: ((Int32) -> Void)? { get set }
    func start() async throws
    func stop()
}

@MainActor
protocol WebSocketManaging: AnyObject {
    var onEvent: ((String, [String: Any]?) -> Void)? { get set }
    var onBinaryMessage: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func connect(to url: URL)
    func disconnect()
    func sendRequest(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> Any
    func sendBinaryFrame(_ data: Data) async throws
}
