import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class RelayEndpointTests: XCTestCase {
    func testBoundedFrameBufferDropsOldest() {
        let connection = MockDaemonConnection(state: .connected)
        let endpoint = RelayEndpoint(
            channelID: 9,
            threadID: "thread-1",
            preset: "terminal",
            sessionID: "terminal",
            connectionManager: connection,
            surfaceHost: MockSurfaceHost()
        )

        for i in 0...1000 {
            endpoint.handleBinaryFrame(makeFrame(channelID: 9, payload: [UInt8(i & 0xFF)]))
        }

        XCTAssertEqual(endpoint.bufferedFrameCount, 1000)
        XCTAssertEqual(endpoint.bufferedFrame(at: 0)?[2], 1)
        XCTAssertEqual(endpoint.bufferedFrame(at: 999)?[2], UInt8(1000 & 0xFF))
        endpoint.stop()
    }

    func testChannelGateBlocksInputWhenChannelIDIsZero() async {
        let connection = MockDaemonConnection(state: .connected)
        let endpoint = RelayEndpoint(
            channelID: 0,
            threadID: "thread-1",
            preset: "terminal",
            sessionID: "terminal",
            connectionManager: connection,
            surfaceHost: MockSurfaceHost()
        )

        endpoint.forwardRelayPayloadForTesting(Data([0x41]))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(connection.sentBinaryFrames.isEmpty)

        endpoint.setChannelID(12)
        endpoint.forwardRelayPayloadForTesting(Data([0x42]))

        let sent = await waitForCondition { connection.sentBinaryFrames.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(Array(connection.sentBinaryFrames[0]), [0x00, 0x0C, 0x42])
        endpoint.stop()
    }

    func testChannelRemapUpdatesActiveChannel() {
        let connection = MockDaemonConnection(state: .connected)
        let endpoint = RelayEndpoint(
            channelID: 4,
            threadID: "thread-1",
            preset: "terminal",
            sessionID: "terminal",
            connectionManager: connection,
            surfaceHost: MockSurfaceHost()
        )

        endpoint.handleBinaryFrame(makeFrame(channelID: 4, payload: [0x11]))
        endpoint.setChannelID(7)
        endpoint.handleBinaryFrame(makeFrame(channelID: 4, payload: [0x22]))
        endpoint.handleBinaryFrame(makeFrame(channelID: 7, payload: [0x33]))

        XCTAssertEqual(endpoint.bufferedFrameCount, 2)
        XCTAssertEqual(endpoint.bufferedFrame(at: 0)?[2], 0x11)
        XCTAssertEqual(endpoint.bufferedFrame(at: 1)?[2], 0x33)
        endpoint.stop()
    }
}
