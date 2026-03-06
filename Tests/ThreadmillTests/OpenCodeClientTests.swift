import Foundation
import XCTest
@testable import Threadmill

final class OpenCodeClientTests: XCTestCase {
    func testListSessionsSendsEncodedDirectoryHeaderAndDecodesResponse() async throws {
        TestURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "%2Fhome%2Fwsl%2Fdev%2Fmy%20autonomy")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.percentEncodedPath, "/session")
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "directory" })?.value, "/home/wsl/dev/my autonomy")

            let payload = """
            [
              {
                "id": "ses_1",
                "slug": "bright-river",
                "projectID": "proj_1",
                "directory": "/home/wsl/dev/my autonomy",
                "title": "Session title",
                "version": "1.1.65",
                "time": { "created": 1, "updated": 2 }
              }
            ]
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }

        let client = makeClient()
        let sessions = try await client.listSessions(directory: "/home/wsl/dev/my autonomy")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "ses_1")
        XCTAssertEqual(sessions.first?.projectID, "proj_1")
    }

    func testListSessionsUsesBasicAuthWhenCredentialsProvided() async throws {
        TestURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
            let payload = "[]".data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }

        let client = makeClient(username: "user", password: "pass")
        _ = try await client.listSessions(directory: "/tmp/worktree")
    }

    func testSSEParserParsesKnownEventsAcrossChunks() throws {
        var parser = OCSSEParser()
        let payload = """
        data: {"type":"session.updated","properties":{"info":{"id":"ses_1","slug":"s","projectID":"p","directory":"/tmp","title":"t","version":"1","time":{"created":1,"updated":2}}}}

        data: {"type":"message.part.updated","properties":{"part":{"id":"prt_1","sessionID":"ses_1","messageID":"msg_1","type":"text","text":"Hel"},"delta":"Hel"}}

        data: {"type":"message.updated","properties":{"info":{"id":"msg_1","sessionID":"ses_1","role":"assistant","time":{"created":1}}}}

        data: {"type":"session.status","properties":{"sessionID":"ses_1","status":{"type":"busy"}}}

        data: {"type":"custom.event","properties":{"foo":"bar"}}

        """
        let completePayload = payload + "\n\n"
        let splitIndex = completePayload.index(completePayload.startIndex, offsetBy: completePayload.count / 2)
        let chunk1 = Data(completePayload[completePayload.startIndex..<splitIndex].utf8)
        let chunk2 = Data(completePayload[splitIndex..<completePayload.endIndex].utf8)

        let events1 = try parser.append(chunk1)
        let events2 = try parser.append(chunk2)
        let events = events1 + events2

        XCTAssertEqual(events.count, 5)
        guard events.count == 5 else {
            return
        }

        if case let .sessionUpdated(session) = events[0] {
            XCTAssertEqual(session.id, "ses_1")
        } else {
            XCTFail("Expected sessionUpdated event")
        }

        if case let .messagePartUpdated(update) = events[1] {
            XCTAssertEqual(update.part.id, "prt_1")
            XCTAssertEqual(update.delta, "Hel")
        } else {
            XCTFail("Expected messagePartUpdated event")
        }

        if case let .messageUpdated(message) = events[2] {
            XCTAssertEqual(message.id, "msg_1")
        } else {
            XCTFail("Expected messageUpdated event")
        }

        if case let .sessionStatus(status) = events[3] {
            XCTAssertEqual(status.sessionID, "ses_1")
            XCTAssertEqual(status.status.type, "busy")
        } else {
            XCTFail("Expected sessionStatus event")
        }

        if case let .unknown(eventType, _) = events[4] {
            XCTAssertEqual(eventType, "custom.event")
        } else {
            XCTFail("Expected unknown event")
        }
    }

    func testMockOpenCodeClientRecordsPromptCalls() async throws {
        let mock = MockOpenCodeClient()
        try await mock.sendPrompt(sessionID: "ses_1", prompt: "Hello", directory: "/tmp/worktree")

        XCTAssertEqual(mock.promptedSessions.count, 1)
        XCTAssertEqual(mock.promptedSessions.first?.sessionID, "ses_1")
        XCTAssertEqual(mock.promptedSessions.first?.prompt, "Hello")
        XCTAssertEqual(mock.promptedSessions.first?.directory, "/tmp/worktree")
    }

    func testCreateSessionUsesSessionCollectionEndpoint() async throws {
        TestURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(components?.percentEncodedPath, "/session")
            XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "directory" })?.value, "/tmp/worktree")

            let payload = """
            {
              "id": "ses_1",
              "projectID": "proj_1",
              "directory": "/tmp/worktree",
              "title": "Session",
              "version": "1.1.65",
              "time": { "created": 1, "updated": 2 }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }

        let client = makeClient()
        let session = try await client.createSession(directory: "/tmp/worktree")
        XCTAssertEqual(session.id, "ses_1")
        XCTAssertNil(session.slug)
    }

    func testCreateSessionWithAgentSendsAgentPayload() async throws {
        TestURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(components?.percentEncodedPath, "/session")

            let body = try OpenCodeClientTests.requestBodyData(from: request)
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(payload?["agent"] as? String, "my-agent")

            let response = """
            {
              "id": "ses_1",
              "projectID": "proj_1",
              "directory": "/tmp/worktree",
              "title": "Session",
              "version": "1.1.65",
              "time": { "created": 1, "updated": 2 }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let client = makeClient()
        let session = try await client.createSession(directory: "/tmp/worktree", agentID: "my-agent")
        XCTAssertEqual(session.id, "ses_1")
    }

    func testInitSessionUsesExplicitModelWithoutProviderLookup() async throws {
        var requestPaths: [String] = []

        TestURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let path = components?.percentEncodedPath ?? ""
            requestPaths.append(path)

            if path == "/session/ses_1/init" {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try OpenCodeClientTests.requestBodyData(from: request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["providerID"] as? String, "anthropic")
                XCTAssertEqual(payload?["modelID"] as? String, "claude-sonnet")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }

            if path == "/session/ses_1" {
                let payload = """
                {
                  "id": "ses_1",
                  "projectID": "proj_1",
                  "directory": "/tmp/worktree",
                  "title": "Session",
                  "version": "1.1.65",
                  "time": { "created": 1, "updated": 2 }
                }
                """.data(using: .utf8)!
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    payload
                )
            }

            XCTFail("Unexpected path: \(path)")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let client = makeClient()
        let session = try await client.initSession(
            id: "ses_1",
            directory: "/tmp/worktree",
            model: OCMessageModel(providerID: "anthropic", modelID: "claude-sonnet")
        )

        XCTAssertEqual(session.id, "ses_1")
        XCTAssertFalse(requestPaths.contains("/provider"))
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer {
            stream.close()
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw stream.streamError ?? NSError(domain: "OpenCodeClientTests", code: 1)
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }

    func testGetSessionEscapesForwardSlashesInPathComponents() async throws {
        TestURLProtocol.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.percentEncodedPath, "/session/ses_malicious%2Fsubpath")

            let payload = """
            {
              "id": "ses_malicious/subpath",
              "projectID": "proj_1",
              "directory": "/tmp/worktree",
              "title": "Session",
              "version": "1.1.65",
              "time": { "created": 1, "updated": 2 }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                payload
            )
        }

        let client = makeClient()
        _ = try await client.getSession(id: "ses_malicious/subpath", directory: "/tmp/worktree")
    }

    func testSSEParserUsesExplicitEventFieldWhenTypeIsMissingInData() throws {
        var parser = OCSSEParser()
        let payload = """
        event: session.status
        data: {"properties":{"sessionID":"ses_1","status":{"type":"idle"}}}

        """

        let events = try parser.append(Data((payload + "\n").utf8))
        XCTAssertEqual(events.count, 1)

        guard case let .sessionStatus(status) = events.first else {
            return XCTFail("Expected sessionStatus event")
        }

        XCTAssertEqual(status.sessionID, "ses_1")
        XCTAssertEqual(status.status.type, "idle")
    }

    private func makeClient(username: String? = nil, password: String? = nil) -> OpenCodeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return OpenCodeClient(
            baseURL: URL(string: "http://127.0.0.1:4101")!,
            username: username,
            password: password,
            session: session
        )
    }
}

private final class TestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            XCTFail("Missing requestHandler")
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
