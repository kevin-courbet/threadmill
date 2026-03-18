import XCTest
@testable import Threadmill

@MainActor
final class ConnectionManagerTests: XCTestCase {
    func testReconnectCancellationStopsRetryLoop() async {
        let tunnel = MockTunnelManager()
        tunnel.enqueueStartResult(.failure(TestError.forcedFailure))

        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { _, _, _ in "pong" }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 4,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        let reconnectScheduled = await waitForCondition {
            if case let .reconnecting(attempt) = manager.state {
                return attempt == 1
            }
            return false
        }
        XCTAssertTrue(reconnectScheduled)
        XCTAssertEqual(tunnel.startCallCount, 1)

        manager.cancelScheduledReconnect()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(tunnel.startCallCount, 1)
        manager.stop()
    }

    func testStateTransitionsDisconnectedConnectingConnected() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "ping" {
                return "pong"
            }
            if method == "session.hello" {
                return ["session_id": "sess-1"]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 1,
            reconnectDelay: { _ in 0.05 }
        )

        var states: [ConnectionStatus] = []
        manager.onStateChange = { states.append($0) }

        XCTAssertEqual(manager.state, .disconnected)

        manager.start()

        let connected = await waitForCondition { manager.state == .connected }
        XCTAssertTrue(connected)
        XCTAssertEqual(Array(states.prefix(2)), [.connecting, .connected])
        XCTAssertEqual(tunnel.startCallCount, 1)
        XCTAssertEqual(webSocket.connectURLs.count, 1)
        XCTAssertEqual(webSocket.sentRequests.map(\.method), ["ping", "session.hello"])
        manager.stop()
    }

    func testSessionHelloFailurePreventsConnectedState() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()

        webSocket.requestHandler = { method, _, _ in
            switch method {
            case "ping":
                return "pong"
            case "session.hello":
                throw TestError.forcedFailure
            default:
                return ["ok": true]
            }
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(manager.state, .connected)
        XCTAssertEqual(Array(webSocket.sentRequests.prefix(2).map(\.method)), ["ping", "session.hello"])
        manager.stop()
    }

    func testDebugSnapshotReflectsSessionNegotiationFailure() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "ping" {
                return "pong"
            }
            if method == "session.hello" {
                throw TestError.forcedFailure
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 1,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = manager.debugSnapshot
        XCTAssertFalse(snapshot.sessionReady)
        XCTAssertNotNil(snapshot.lastErrorDescription)
        XCTAssertNotEqual(snapshot.status, .connected)

        manager.stop()
    }
}
