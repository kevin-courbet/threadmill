import XCTest
@testable import Threadmill

@MainActor
final class TerminalMultiplexerTests: XCTestCase {
    func testAttachReturnsEndpointWithChannelID() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, params, _ in
            if method == "terminal.attach" {
                XCTAssertEqual(params?["thread_id"] as? String, "thread-1")
                XCTAssertEqual(params?["preset"] as? String, "terminal")
                XCTAssertEqual(params?["session_id"] as? String, "terminal-2")
                return ["channel_id": 7]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        let endpoint = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal-2", preset: "terminal")

        XCTAssertEqual(endpoint.channelID, 7)
        XCTAssertTrue(multiplexer.endpoint(threadID: "thread-1", sessionID: "terminal-2") === endpoint)
        multiplexer.detachAll()
    }

    func testDetachRemovesEndpoint() async throws {
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            if method == "terminal.attach" {
                return ["channel_id": 12]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        _ = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")

        multiplexer.detach(channelID: 12)

        XCTAssertNil(multiplexer.endpoint(threadID: "thread-1", sessionID: "terminal"))
    }

    func testDispatchRoutesBinaryFramesToMatchingEndpoint() async throws {
        var channelsByThread: [String: UInt16] = ["thread-1": 21, "thread-2": 22]
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, params, _ in
            if method == "terminal.attach" {
                let threadID = params?["thread_id"] as? String ?? ""
                return ["channel_id": Int(channelsByThread[threadID] ?? 0)]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        let first = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-2", sessionID: "terminal", preset: "terminal")

        multiplexer.handleBinaryFrame(makeFrame(channelID: 22, payload: [0xAA]))

        XCTAssertEqual(first.bufferedFrameCount, 0)
        XCTAssertEqual(second.bufferedFrameCount, 1)
        multiplexer.detachAll()
        channelsByThread.removeAll()
    }

    func testReattachAllRemapsChannelsAfterReconnect() async throws {
        var channelsByThread: [String: UInt16] = ["thread-1": 30, "thread-2": 31]
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, params, _ in
            if method == "terminal.attach" {
                let threadID = params?["thread_id"] as? String ?? ""
                return ["channel_id": Int(channelsByThread[threadID] ?? 0)]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        let first = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-2", sessionID: "terminal", preset: "terminal")

        channelsByThread = ["thread-1": 80, "thread-2": 81]
        await multiplexer.reattachAll()

        XCTAssertEqual(first.channelID, 80)
        XCTAssertEqual(second.channelID, 81)

        multiplexer.handleBinaryFrame(makeFrame(channelID: 80, payload: [0x10]))
        multiplexer.handleBinaryFrame(makeFrame(channelID: 81, payload: [0x20]))
        XCTAssertEqual(first.bufferedFrameCount, 1)
        XCTAssertEqual(second.bufferedFrameCount, 1)
        multiplexer.detachAll()
    }

    func testPreRegistrationFramesBufferedAndFlushedOnAttach() async throws {
        // Spindle sends scrollback replay binary frames BEFORE the
        // terminal.attach RPC response arrives. The multiplexer must
        // buffer these and flush them once the endpoint is registered.
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            if method == "terminal.attach" {
                return ["channel_id": 42]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())

        // Simulate scrollback replay arriving before attach completes
        let scrollbackFrame = makeFrame(channelID: 42, payload: Array("scrollback data".utf8))
        multiplexer.handleBinaryFrame(scrollbackFrame)

        // Attach registers the endpoint and flushes buffered frames
        let endpoint = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")

        XCTAssertEqual(endpoint.channelID, 42)
        XCTAssertEqual(endpoint.bufferedFrameCount, 1)
        multiplexer.detachAll()
    }

    func testAttachSameThreadPresetTwiceReusesEndpoint() async throws {
        var channelID: UInt16 = 41
        let connection = MockDaemonConnection(state: .connected)
        connection.requestHandler = { method, _, _ in
            if method == "terminal.attach" {
                return ["channel_id": Int(channelID)]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())

        let first = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")
        XCTAssertTrue(first === second)

        first.setChannelID(0)
        channelID = 55
        let third = try await multiplexer.attach(threadID: "thread-1", sessionID: "terminal", preset: "terminal")

        XCTAssertTrue(first === third)
        XCTAssertEqual(third.channelID, 55)
        XCTAssertEqual(connection.requests.filter { $0.method == "terminal.attach" }.count, 2)
        multiplexer.detachAll()
    }

    func testAttachDetachAndBinarySendUseConnectionForThread() async throws {
        let remoteAConnection = MockDaemonConnection(state: .connected)
        let remoteBConnection = MockDaemonConnection(state: .connected)

        remoteAConnection.requestHandler = { method, params, _ in
            if method == "terminal.attach" {
                XCTAssertEqual(params?["session_id"] as? String, "terminal")
                return ["channel_id": 11]
            }
            if method == "terminal.detach" {
                XCTAssertEqual(params?["session_id"] as? String, "terminal")
                return ["detached": true]
            }
            return NSNull()
        }

        remoteBConnection.requestHandler = { method, params, _ in
            if method == "terminal.attach" {
                XCTAssertEqual(params?["session_id"] as? String, "terminal")
                return ["channel_id": 22]
            }
            if method == "terminal.detach" {
                XCTAssertEqual(params?["session_id"] as? String, "terminal")
                return ["detached": true]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(
            connectionResolver: { threadID in
                switch threadID {
                case "thread-a":
                    remoteAConnection
                case "thread-b":
                    remoteBConnection
                default:
                    nil
                }
            },
            surfaceHost: MockSurfaceHost()
        )

        let endpointA = try await multiplexer.attach(threadID: "thread-a", sessionID: "terminal", preset: "terminal")
        let endpointB = try await multiplexer.attach(threadID: "thread-b", sessionID: "terminal", preset: "terminal")
        endpointA.forwardRelayPayloadForTesting(Data([0x01, 0x02]))
        endpointB.forwardRelayPayloadForTesting(Data([0x03]))

        multiplexer.detach(threadID: "thread-a", sessionID: "terminal")
        multiplexer.detach(threadID: "thread-b", sessionID: "terminal")

        let sentFrameExpectation = expectation(description: "sent frames routed")
        Task { @MainActor in
            let routed = await waitForCondition {
                remoteAConnection.sentBinaryFrames.count == 1 && remoteBConnection.sentBinaryFrames.count == 1
            }
            XCTAssertTrue(routed)

            XCTAssertEqual(remoteAConnection.requests.filter { $0.method == "terminal.attach" }.count, 1)
            XCTAssertEqual(remoteBConnection.requests.filter { $0.method == "terminal.attach" }.count, 1)
            XCTAssertEqual(remoteAConnection.requests.filter { $0.method == "terminal.detach" }.count, 1)
            XCTAssertEqual(remoteBConnection.requests.filter { $0.method == "terminal.detach" }.count, 1)
            XCTAssertEqual(remoteAConnection.sentBinaryFrames.first, makeFrame(channelID: 11, payload: [0x01, 0x02]))
            XCTAssertEqual(remoteBConnection.sentBinaryFrames.first, makeFrame(channelID: 22, payload: [0x03]))

            sentFrameExpectation.fulfill()
        }
        await fulfillment(of: [sentFrameExpectation], timeout: 1)
    }
}
