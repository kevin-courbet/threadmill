import Foundation

enum OpenCodeClientError: LocalizedError {
    case unavailable
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "OpenCode integration has been fridged in the ACP migration."
        case let .unexpectedStatusCode(status):
            return "Unexpected HTTP status code: \(status)."
        }
    }
}

final class OpenCodeClient: OpenCodeManaging {
    func listSessions(directory _: String) async throws -> [OCSession] {
        throw OpenCodeClientError.unavailable
    }

    func getSession(id _: String, directory _: String) async throws -> OCSession {
        throw OpenCodeClientError.unavailable
    }

    func createSession(directory _: String) async throws -> OCSession {
        throw OpenCodeClientError.unavailable
    }

    func initSession(id _: String, directory _: String) async throws -> OCSession {
        throw OpenCodeClientError.unavailable
    }

    func getMessages(sessionID _: String, directory _: String) async throws -> [OCMessage] {
        throw OpenCodeClientError.unavailable
    }

    func sendPrompt(sessionID _: String, prompt _: String, directory _: String) async throws {
        throw OpenCodeClientError.unavailable
    }

    func abort(sessionID _: String, directory _: String) async throws {
        throw OpenCodeClientError.unavailable
    }

    func getSessionDiff(sessionID _: String, directory _: String) async throws -> OCDiff {
        throw OpenCodeClientError.unavailable
    }

    func healthCheck() async throws -> Bool {
        false
    }

    func streamEvents(directory _: String) -> AsyncStream<OCEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func invalidate() {}
}
