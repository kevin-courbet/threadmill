import XCTest
@testable import Threadmill

@MainActor
final class AppStateCancelThreadCreationTests: XCTestCase {
    func testCancelThreadCreationSendsThreadCancelRPC() async {
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

        await appState.cancelThreadCreation(threadID: "thread-1")

        XCTAssertEqual(webSocket.sentRequests.count, 1)
        XCTAssertEqual(webSocket.sentRequests[0].method, "thread.cancel")
        XCTAssertEqual(webSocket.sentRequests[0].params?["thread_id"] as? String, "thread-1")
    }
}
