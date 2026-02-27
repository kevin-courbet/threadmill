import XCTest
@testable import Threadmill

@MainActor
final class AppStateCreateThreadPRURLTests: XCTestCase {
    func testCreateThreadWithPullRequestIncludesPRURLParam() async throws {
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

        try await appState.createThread(
            projectID: "project-1",
            name: "new-thread",
            sourceType: "pull_request",
            branch: nil,
            prURL: "https://github.com/org/repo/pull/123"
        )

        XCTAssertEqual(webSocket.sentRequests.count, 1)
        XCTAssertEqual(webSocket.sentRequests[0].method, "thread.create")
        XCTAssertEqual(webSocket.sentRequests[0].params?["source_type"] as? String, "pull_request")
        XCTAssertEqual(webSocket.sentRequests[0].params?["pr_url"] as? String, "https://github.com/org/repo/pull/123")
        XCTAssertNil(webSocket.sentRequests[0].params?["branch"])
    }
}
