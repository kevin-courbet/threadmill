import Foundation
import XCTest

final class MockSpindleServerSystemMethodsTests: XCTestCase {
    func testSystemCleanupMethodIsRejected() async throws {
        let server = MockSpindleServer()
        try server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(server.port)"))
        let session = URLSession(configuration: .ephemeral)
        let webSocket = session.webSocketTask(with: url)
        webSocket.resume()
        defer {
            webSocket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await sendRequest(
            webSocket,
            id: 1,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": [],
            ]
        )

        let cleanupResponse = try await sendRequest(webSocket, id: 2, method: "system.cleanup")
        let error = try XCTUnwrap(cleanupResponse["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["kind"] as? String, "rpc.method_not_found")
    }

    private func sendRequest(
        _ webSocket: URLSessionWebSocketTask,
        id: Int,
        method: String,
        params: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params {
            payload["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let requestText = try XCTUnwrap(String(data: requestData, encoding: .utf8))
        try await webSocket.send(.string(requestText))

        let message = try await webSocket.receive()
        let responseData: Data
        switch message {
        case .string(let text):
            responseData = try XCTUnwrap(text.data(using: .utf8))
        case .data(let data):
            responseData = data
        @unknown default:
            XCTFail("Unexpected WebSocket message")
            throw NSError(domain: "MockSpindleServerSystemMethodsTests", code: 1)
        }

        let object = try JSONSerialization.jsonObject(with: responseData, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }
}
