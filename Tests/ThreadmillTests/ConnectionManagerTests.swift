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
            if method == "session.hello" {
                return [
                    "session_id": "session-1",
                    "protocol_version": "2026-03-17",
                    "capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                    "state_version": 1,
                ]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
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
        XCTAssertEqual(webSocket.sentRequests.first?.method, "session.hello")
        manager.stop()
    }

    func testConnectFailureWhenSessionHelloRejectedSchedulesReconnect() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                throw JSONRPCErrorResponse(code: -32601, message: "Method not found: session.hello")
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 4,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        let reconnecting = await waitForCondition {
            if case .reconnecting = manager.state {
                return true
            }
            return false
        }
        XCTAssertTrue(reconnecting)
        XCTAssertEqual(webSocket.sentRequests.first?.method, "session.hello")
        XCTAssertEqual(webSocket.sentRequests.filter { $0.method == "ping" }.count, 0)
        manager.stop()
    }

    func testSessionHelloProtocolMismatchSchedulesReconnect() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                return [
                    "session_id": "session-1",
                    "protocol_version": "2024-01-01",
                    "capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                    "state_version": 1,
                ]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 4,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        let reconnecting = await waitForCondition {
            if case .reconnecting = manager.state {
                return true
            }
            return false
        }
        XCTAssertTrue(reconnecting)
        manager.stop()
    }

    func testEventsBeforeSessionHelloAreDropped() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                throw JSONRPCErrorResponse(code: -32000, message: "session.hello rejected")
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 4,
            reconnectDelay: { _ in 0.05 }
        )

        var events: [(String, [String: Any]?)] = []
        manager.onEvent = { method, params in
            events.append((method, params))
        }

        manager.start()

        let reconnecting = await waitForCondition {
            if case .reconnecting = manager.state {
                return true
            }
            return false
        }
        XCTAssertTrue(reconnecting)

        webSocket.emitEvent(method: "thread.created", params: ["thread": ["id": "t-1"]])
        XCTAssertTrue(events.isEmpty)
        manager.stop()
    }

    func testSessionHelloMissingCapabilitiesSchedulesReconnect() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                return [
                    "session_id": "session-1",
                    "protocol_version": "2026-03-17",
                    "capabilities": ["state.delta.operations.v1"],
                    "state_version": 1,
                ]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            maxReconnectAttempts: 4,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        let reconnecting = await waitForCondition {
            if case .reconnecting = manager.state {
                return true
            }
            return false
        }
        XCTAssertTrue(reconnecting)
        manager.stop()
    }

    func testSessionHelloSendsDistinctRequiredCapabilitiesContract() async throws {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                return [
                    "session_id": "session-1",
                    "protocol_version": "2026-03-17",
                    "capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                    "required_capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                    "state_version": 1,
                ]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            reconnectDelay: { _ in 0.05 }
        )

        manager.start()

        let connected = await waitForCondition { manager.state == .connected }
        XCTAssertTrue(connected)

        let params = try XCTUnwrap(webSocket.sentRequests.first?.params)
        let capabilities = try XCTUnwrap(params["capabilities"] as? [String])
        let requiredCapabilities = try XCTUnwrap(params["required_capabilities"] as? [String])
        XCTAssertEqual(Set(capabilities), Set(requiredCapabilities))

        manager.stop()
    }

    func testSessionHelloEmitsBaselineEvent() async {
        let tunnel = MockTunnelManager()
        let webSocket = MockWebSocketClient()
        webSocket.requestHandler = { method, _, _ in
            if method == "session.hello" {
                return [
                    "session_id": "session-1",
                    "protocol_version": "2026-03-17",
                    "capabilities": [
                        "state.delta.operations.v1",
                        "preset.output.v1",
                        "rpc.errors.structured.v1",
                    ],
                    "state_version": 9,
                ]
            }
            throw TestError.missingStub
        }

        let manager = ConnectionManager(
            config: ThreadmillConfig(host: "beast", daemonPort: 19990, useSSHTunnel: true),
            tunnelManager: tunnel,
            webSocketClient: webSocket,
            reconnectDelay: { _ in 0.05 }
        )

        var baselineStateVersion: Int?
        manager.onEvent = { method, params in
            guard method == "session.hello" else {
                return
            }
            baselineStateVersion = params?["state_version"] as? Int
        }

        manager.start()

        let connected = await waitForCondition { manager.state == .connected }
        XCTAssertTrue(connected)
        XCTAssertEqual(baselineStateVersion, 9)
        manager.stop()
    }
}
