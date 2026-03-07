import Foundation

enum OpenCodeClientError: LocalizedError {
    case invalidURL(path: String)
    case invalidResponse
    case unexpectedStatusCode(Int)
    case missingDefaultModel
    case invalidSSEPayload

    var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            "Invalid OpenCode API URL for path \(path)."
        case .invalidResponse:
            "Received a non-HTTP response from OpenCode API."
        case let .unexpectedStatusCode(code):
            "OpenCode API returned unexpected status code \(code)."
        case .missingDefaultModel:
            "Unable to determine a default provider/model for session initialization."
        case .invalidSSEPayload:
            "Received invalid UTF-8 from OpenCode SSE stream."
        }
    }
}

final class OpenCodeClient: OpenCodeManaging {
    private let baseURL: URL
    private let username: String?
    private let password: String?
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private static let directoryHeaderAllowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let pathComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:4101")!,
        username: String? = nil,
        password: String? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    func listSessions(directory: String) async throws -> [OCSession] {
        let data = try await performDataRequest(pathComponents: ["session"], method: "GET", directory: directory)
        return try decoder.decode([OCSession].self, from: data)
    }

    func getSession(id: String, directory: String) async throws -> OCSession {
        let data = try await performDataRequest(pathComponents: ["session", id], method: "GET", directory: directory)
        return try decoder.decode(OCSession.self, from: data)
    }

    func createSession(directory: String) async throws -> OCSession {
        let data = try await performDataRequest(pathComponents: ["session"], method: "POST", directory: directory)
        return try decoder.decode(OCSession.self, from: data)
    }

    func initSession(id: String, directory: String) async throws -> OCSession {
        let sessionID = id
        let providers = try await getProvidersPayload(directory: directory)
        guard let model = defaultModel(from: providers) else {
            throw OpenCodeClientError.missingDefaultModel
        }

        let initRequest = OCSessionInitRequest(
            modelID: model.modelID,
            providerID: model.providerID,
            messageID: Self.makeMessageID()
        )
        let body = try encoder.encode(initRequest)
        _ = try await performDataRequest(pathComponents: ["session", sessionID, "init"], method: "POST", directory: directory, body: body)

        return try await getSession(id: id, directory: directory)
    }

    func getMessages(sessionID: String, directory: String) async throws -> [OCMessage] {
        let data = try await performDataRequest(pathComponents: ["session", sessionID, "message"], method: "GET", directory: directory)
        let payload = try decoder.decode([OCMessageEnvelope].self, from: data)
        return payload.map { envelope in
            envelope.info.withParts(envelope.parts)
        }
    }

    func sendPrompt(sessionID: String, prompt: String, directory: String) async throws {
        let payload = OCPromptRequest(
            messageID: Self.makeMessageID(),
            parts: [OCTextPromptPart(type: "text", text: prompt)]
        )
        let body = try encoder.encode(payload)

        _ = try await performDataRequest(
            pathComponents: ["session", sessionID, "prompt_async"],
            method: "POST",
            directory: directory,
            body: body
        )
    }

    func abort(sessionID: String, directory: String) async throws {
        _ = try await performDataRequest(pathComponents: ["session", sessionID, "abort"], method: "POST", directory: directory)
    }

    func getSessionDiff(sessionID: String, directory: String) async throws -> OCDiff {
        let data = try await performDataRequest(pathComponents: ["session", sessionID, "diff"], method: "GET", directory: directory)
        let files = try decoder.decode([OCDiffFile].self, from: data)
        return OCDiff(files: files)
    }

    func healthCheck() async throws -> Bool {
        let data = try await performDataRequest(pathComponents: ["global", "health"], method: "GET", directory: nil)
        let response = try decoder.decode(OCHealthResponse.self, from: data)
        return response.healthy
    }

    func streamEvents(directory: String) -> AsyncStream<OCEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(pathComponents: ["event"], method: "GET", directory: directory, body: nil)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateResponse(response)

                    var parser = OCSSEParser()
                    for try await line in bytes.lines {
                        let payload = Data((line + "\n").utf8)
                        let events = try parser.append(payload)
                        for event in events {
                            continuation.yield(event)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.yield(.unknown("stream.error", Data(error.localizedDescription.utf8)))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func getProvidersPayload(directory: String) async throws -> OCProvidersPayload {
        let data = try await performDataRequest(pathComponents: ["provider"], method: "GET", directory: directory)

        if let payload = try? decoder.decode(OCProvidersPayload.self, from: data) {
            return payload
        }

        let providers = try decoder.decode([OCProviderPayload].self, from: data)
        return OCProvidersPayload(all: providers, connected: [], defaultModelByProvider: [:])
    }

    private func defaultModel(from payload: OCProvidersPayload) -> OCMessageModel? {
        for providerID in payload.connected {
            if let modelID = payload.defaultModelByProvider[providerID] {
                return OCMessageModel(providerID: providerID, modelID: modelID)
            }
        }

        if let (providerID, modelID) = payload.defaultModelByProvider.first {
            return OCMessageModel(providerID: providerID, modelID: modelID)
        }

        for provider in payload.all {
            if let (key, model) = provider.models.first {
                return OCMessageModel(providerID: provider.id, modelID: model.id ?? key)
            }
        }

        return nil
    }

    private func performDataRequest(pathComponents: [String], method: String, directory: String?, body: Data? = nil) async throws -> Data {
        let request = try makeRequest(pathComponents: pathComponents, method: method, directory: directory, body: body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }

    private func makeRequest(pathComponents: [String], method: String, directory: String?, body: Data?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeClientError.invalidURL(path: pathComponents.joined(separator: "/"))
        }

        let encodedPathComponents = pathComponents.map(encodePathComponent)
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = encodedPathComponents.joined(separator: "/")
        let fullPath = [basePath, joinedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/\(fullPath)"

        if let directory {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "directory", value: directory))
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw OpenCodeClientError.invalidURL(path: pathComponents.joined(separator: "/"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let directory {
            request.setValue(encodeDirectoryHeader(directory), forHTTPHeaderField: "x-opencode-directory")
        }

        if let username, let password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw OpenCodeClientError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    private func encodeDirectoryHeader(_ directory: String) -> String {
        directory.addingPercentEncoding(withAllowedCharacters: Self.directoryHeaderAllowedCharacters) ?? directory
    }

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters) ?? value
    }

    private static func makeMessageID() -> String {
        "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

struct OCSSEParser {
    private var buffer = ""
    private let decoder = JSONDecoder()

    mutating func append(_ data: Data) throws -> [OCEvent] {
        guard let chunk = String(data: data, encoding: .utf8) else {
            throw OpenCodeClientError.invalidSSEPayload
        }

        buffer.append(chunk.replacingOccurrences(of: "\r\n", with: "\n"))

        var events: [OCEvent] = []

        while let range = buffer.range(of: "\n\n") {
            let eventRecord = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)

            if let event = decodeEventRecord(eventRecord) {
                events.append(event)
            }
        }

        return events
    }

    private func decodeEventRecord(_ record: String) -> OCEvent? {
        var explicitEventType: String?
        var payloadLines: [String] = []

        for line in record.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("event:") {
                explicitEventType = line
                    .dropFirst("event:".count)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("data:") {
                var value = line.dropFirst("data:".count)
                if value.first == " " {
                    value = value.dropFirst()
                }
                payloadLines.append(String(value))
            }
        }

        guard !payloadLines.isEmpty else {
            return nil
        }

        let payloadText = payloadLines.joined(separator: "\n")
        guard let payloadData = payloadText.data(using: .utf8) else {
            return nil
        }

        let inferredType: String
        if let explicitEventType {
            inferredType = explicitEventType
        } else if let envelope = try? decoder.decode(OCEventTypeEnvelope.self, from: payloadData) {
            inferredType = envelope.type
        } else {
            inferredType = "unknown"
        }

        switch inferredType {
        case "session.updated":
            guard let envelope = try? decoder.decode(OCSessionUpdatedEnvelope.self, from: payloadData) else {
                return .unknown(inferredType, payloadData)
            }
            return .sessionUpdated(envelope.properties.info)

        case "message.updated":
            guard let envelope = try? decoder.decode(OCMessageUpdatedEnvelope.self, from: payloadData) else {
                return .unknown(inferredType, payloadData)
            }
            return .messageUpdated(envelope.properties.info)

        case "message.part.updated":
            guard let envelope = try? decoder.decode(OCMessagePartUpdatedEnvelope.self, from: payloadData) else {
                return .unknown(inferredType, payloadData)
            }
            return .messagePartUpdated(OCMessagePartUpdate(part: envelope.properties.part, delta: envelope.properties.delta))

        case "session.status":
            guard let envelope = try? decoder.decode(OCSessionStatusEnvelope.self, from: payloadData) else {
                return .unknown(inferredType, payloadData)
            }
            return .sessionStatus(envelope.properties)

        default:
            return .unknown(inferredType, payloadData)
        }
    }
}

private struct OCMessageEnvelope: Decodable {
    let info: OCMessage
    let parts: [OCMessagePart]
}

private struct OCPromptRequest: Encodable {
    let messageID: String
    let parts: [OCTextPromptPart]
}

private struct OCTextPromptPart: Encodable {
    let type: String
    let text: String
}

private struct OCSessionInitRequest: Encodable {
    let modelID: String
    let providerID: String
    let messageID: String
}

private struct OCProvidersPayload: Decodable {
    let all: [OCProviderPayload]
    let connected: [String]
    let defaultModelByProvider: [String: String]

    private enum CodingKeys: String, CodingKey {
        case all
        case connected
        case defaultModelByProvider = "default"
    }
}

private struct OCProviderPayload: Decodable {
    let id: String
    let name: String
    let models: [String: OCModelPayload]
}

private struct OCModelPayload: Decodable {
    let id: String?
    let name: String?
}

private struct OCHealthResponse: Decodable {
    let healthy: Bool
}

private struct OCEventTypeEnvelope: Decodable {
    let type: String
}

private struct OCSessionUpdatedEnvelope: Decodable {
    let properties: OCSessionUpdatedProperties
}

private struct OCSessionUpdatedProperties: Decodable {
    let info: OCSession
}

private struct OCMessageUpdatedEnvelope: Decodable {
    let properties: OCMessageUpdatedProperties
}

private struct OCMessageUpdatedProperties: Decodable {
    let info: OCMessage
}

private struct OCMessagePartUpdatedEnvelope: Decodable {
    let properties: OCMessagePartUpdatedProperties
}

private struct OCMessagePartUpdatedProperties: Decodable {
    let part: OCMessagePart
    let delta: String?
}

private struct OCSessionStatusEnvelope: Decodable {
    let properties: OCSessionStatusEvent
}

private extension OCMessage {
    func withParts(_ parts: [OCMessagePart]) -> OCMessage {
        OCMessage(
            id: id,
            sessionID: sessionID,
            role: role,
            parts: parts,
            agent: agent,
            time: time,
            model: model
        )
    }
}
