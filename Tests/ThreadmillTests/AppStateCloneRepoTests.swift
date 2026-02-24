import XCTest
@testable import Threadmill

@MainActor
final class AppStateCloneRepoTests: XCTestCase {
    func testCloneRepoSendsProjectCloneMethodAndParams() async throws {
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { _, _, _ in NSNull() }

        let appState = AppState()
        appState.configure(
            connectionManager: ConnectionManager(
                config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: false),
                tunnelManager: MockTunnelManager(),
                webSocketClient: webSocket
            ),
            databaseManager: MockDatabaseManager(),
            syncService: MockSyncService(),
            multiplexer: MockTerminalMultiplexer()
        )

        try await appState.cloneRepo(url: "https://github.com/org/repo.git", path: "/home/wsl/dev/")

        XCTAssertEqual(webSocket.sentRequests.count, 1)
        XCTAssertEqual(webSocket.sentRequests[0].method, "project.clone")
        XCTAssertEqual(webSocket.sentRequests[0].params?["url"] as? String, "https://github.com/org/repo.git")
        XCTAssertEqual(webSocket.sentRequests[0].params?["path"] as? String, "/home/wsl/dev/")
    }
}
