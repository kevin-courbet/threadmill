import Foundation
import XCTest

final class MockSpindleServerSystemMethodsTests: XCTestCase {
    private static let requiredCapabilities = [
        "state.delta.operations.v1",
        "preset.output.v1",
        "rpc.errors.structured.v1",
    ]

    func testSystemStatsMethodReturnsPayloadAndCleanupIsRejected() async throws {
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
                "capabilities": Self.requiredCapabilities,
            ]
        )

        let statsResponse = try await sendRequest(webSocket, id: 2, method: "system.stats")
        let stats = try XCTUnwrap(statsResponse["result"] as? [String: Any])
        XCTAssertNotNil(stats["load_avg_1m"])
        XCTAssertNotNil(stats["memory_total_mb"])
        XCTAssertNotNil(stats["memory_used_mb"])
        XCTAssertNotNil(stats["opencode_instances"])

        let cleanupResponse = try await sendRequest(webSocket, id: 3, method: "system.cleanup")
        let error = try XCTUnwrap(cleanupResponse["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["kind"] as? String, "rpc.method_not_found")
    }

    func testSessionHelloRequiresMatchingProtocolCapabilitiesAndSingleInitialization() async throws {
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

        let protocolMismatch = try await sendRequest(
            webSocket,
            id: 1,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-01-01",
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )
        let protocolMismatchError = try XCTUnwrap(protocolMismatch["error"] as? [String: Any])
        XCTAssertEqual(protocolMismatchError["code"] as? Int, -32602)
        let protocolMismatchData = try XCTUnwrap(protocolMismatchError["data"] as? [String: Any])
        XCTAssertEqual(protocolMismatchData["kind"] as? String, "session.protocol_mismatch")

        let missingCapabilities = try await sendRequest(
            webSocket,
            id: 2,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": ["state.delta.operations.v1"],
                "required_capabilities": ["state.delta.operations.v1"],
            ]
        )
        let missingCapabilitiesError = try XCTUnwrap(missingCapabilities["error"] as? [String: Any])
        XCTAssertEqual(missingCapabilitiesError["code"] as? Int, -32602)
        let missingCapabilitiesData = try XCTUnwrap(missingCapabilitiesError["data"] as? [String: Any])
        XCTAssertEqual(missingCapabilitiesData["kind"] as? String, "session.missing_capabilities")
        let missingCapabilitiesDetails = try XCTUnwrap(missingCapabilitiesData["details"] as? [String: Any])
        let missing = try XCTUnwrap(missingCapabilitiesDetails["missing"] as? [String])
        XCTAssertEqual(Set(missing), Set(["preset.output.v1", "rpc.errors.structured.v1"]))

        let accepted = try await sendRequest(
            webSocket,
            id: 3,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )
        let acceptedResult = try XCTUnwrap(accepted["result"] as? [String: Any])
        let acceptedRequiredCapabilities = try XCTUnwrap(acceptedResult["required_capabilities"] as? [String])
        XCTAssertEqual(Set(acceptedRequiredCapabilities), Set(Self.requiredCapabilities))

        let duplicateHello = try await sendRequest(
            webSocket,
            id: 4,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )
        let duplicateHelloError = try XCTUnwrap(duplicateHello["error"] as? [String: Any])
        XCTAssertEqual(duplicateHelloError["code"] as? Int, -32600)
        let duplicateHelloData = try XCTUnwrap(duplicateHelloError["data"] as? [String: Any])
        XCTAssertEqual(duplicateHelloData["kind"] as? String, "session.already_initialized")
    }

    func testBroadcastsAreSuppressedUntilSessionHelloCompletes() async throws {
        let server = MockSpindleServer()
        try server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(server.port)"))

        let senderSession = URLSession(configuration: .ephemeral)
        let sender = senderSession.webSocketTask(with: url)
        sender.resume()

        let probeSession = URLSession(configuration: .ephemeral)
        let probe = probeSession.webSocketTask(with: url)
        probe.resume()

        defer {
            sender.cancel(with: .goingAway, reason: nil)
            senderSession.invalidateAndCancel()
            probe.cancel(with: .goingAway, reason: nil)
            probeSession.invalidateAndCancel()
        }

        _ = try await sendRequest(
            sender,
            id: 1,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )

        _ = try await sendRequest(sender, id: 2, method: "project.add", params: ["path": "/home/wsl/dev/no-hello-receiver"])

        let noBroadcastBeforeHello = expectation(description: "uninitialized client should not receive broadcasts")
        noBroadcastBeforeHello.isInverted = true
        probe.receive { _ in
            noBroadcastBeforeHello.fulfill()
        }
        await fulfillment(of: [noBroadcastBeforeHello], timeout: 0.7)

        probe.cancel(with: .goingAway, reason: nil)
        probeSession.invalidateAndCancel()

        let observerSession = URLSession(configuration: .ephemeral)
        let observer = observerSession.webSocketTask(with: url)
        observer.resume()
        defer {
            observer.cancel(with: .goingAway, reason: nil)
            observerSession.invalidateAndCancel()
        }

        _ = try await sendRequest(
            observer,
            id: 3,
            method: "session.hello",
            params: [
                "client": ["name": "threadmill-macos", "version": "test"],
                "protocol_version": "2026-03-17",
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )

        _ = try await sendRequest(sender, id: 4, method: "project.add", params: ["path": "/home/wsl/dev/hello-receiver"])

        let broadcastAfterHello = expectation(description: "initialized client receives broadcast")
        var observedMethod: String?
        observer.receive { result in
            if case .success(let message) = result {
                let payload: Data?
                switch message {
                case .string(let text):
                    payload = text.data(using: .utf8)
                case .data(let data):
                    payload = data
                @unknown default:
                    payload = nil
                }

                if let payload,
                   let object = try? JSONSerialization.jsonObject(with: payload, options: []),
                   let response = object as? [String: Any] {
                    observedMethod = response["method"] as? String
                }
            }
            broadcastAfterHello.fulfill()
        }
        await fulfillment(of: [broadcastAfterHello], timeout: 1.5)
        XCTAssertEqual(observedMethod, "project.added")
    }

    func testTerminalAttachMissingThreadMatchesSpindleResourceNotFoundContract() async throws {
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
                "capabilities": Self.requiredCapabilities,
                "required_capabilities": Self.requiredCapabilities,
            ]
        )

        let attachResponse = try await sendRequest(
            webSocket,
            id: 2,
            method: "terminal.attach",
            params: ["thread_id": "thread-does-not-exist", "preset": "terminal"]
        )

        let error = try XCTUnwrap(attachResponse["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32004)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["kind"] as? String, "resource.not_found")
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
