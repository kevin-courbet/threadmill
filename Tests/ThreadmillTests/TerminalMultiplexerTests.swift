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
                return ["channel_id": 7]
            }
            return NSNull()
        }

        let multiplexer = TerminalMultiplexer(connectionManager: connection, surfaceHost: MockSurfaceHost())
        let endpoint = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")

        XCTAssertEqual(endpoint.channelID, 7)
        XCTAssertTrue(multiplexer.endpoint(threadID: "thread-1", preset: "terminal") === endpoint)
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
        _ = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")

        multiplexer.detach(channelID: 12)

        XCTAssertNil(multiplexer.endpoint(threadID: "thread-1", preset: "terminal"))
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
        let first = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-2", preset: "terminal")

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
        let first = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-2", preset: "terminal")

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
        let endpoint = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")

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

        let first = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")
        let second = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")
        XCTAssertTrue(first === second)

        first.setChannelID(0)
        channelID = 55
        let third = try await multiplexer.attach(threadID: "thread-1", preset: "terminal")

        XCTAssertTrue(first === third)
        XCTAssertEqual(third.channelID, 55)
        XCTAssertEqual(connection.requests.filter { $0.method == "terminal.attach" }.count, 2)
        multiplexer.detachAll()
    }
}
