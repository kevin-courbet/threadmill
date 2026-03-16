import Foundation

struct ChatHarnessSession {
    let id: String
    let title: String
}

protocol ChatHarnessRuntime: AnyObject {
    var harness: ChatHarness { get }
    func createSession(directory: String) async throws -> ChatHarnessSession
    func getSession(id: String, directory: String) async throws -> ChatHarnessSession
    func getMessages(sessionID: String, directory: String) async throws -> [OCMessage]
    func sendPrompt(sessionID: String, prompt: String, directory: String) async throws
    func abort(sessionID: String, directory: String) async throws
    func streamEvents(directory: String) -> AsyncStream<OCEvent>
    func invalidate()
}

final class OpenCodeHarnessRuntime: ChatHarnessRuntime {
    let harness: ChatHarness = .openCodeServe

    private let client: any OpenCodeManaging

    init(client: any OpenCodeManaging) {
        self.client = client
    }

    func createSession(directory: String) async throws -> ChatHarnessSession {
        let session = try await client.createSession(directory: directory)
        return ChatHarnessSession(id: session.id, title: session.title)
    }

    func getSession(id: String, directory: String) async throws -> ChatHarnessSession {
        let session = try await client.getSession(id: id, directory: directory)
        return ChatHarnessSession(id: session.id, title: session.title)
    }

    func getMessages(sessionID: String, directory: String) async throws -> [OCMessage] {
        try await client.getMessages(sessionID: sessionID, directory: directory)
    }

    func sendPrompt(sessionID: String, prompt: String, directory: String) async throws {
        try await client.sendPrompt(sessionID: sessionID, prompt: prompt, directory: directory)
    }

    func abort(sessionID: String, directory: String) async throws {
        try await client.abort(sessionID: sessionID, directory: directory)
    }

    func streamEvents(directory: String) -> AsyncStream<OCEvent> {
        client.streamEvents(directory: directory)
    }

    func invalidate() {
        client.invalidate()
    }
}

enum ChatHarnessRegistryError: LocalizedError {
    case unsupportedHarness(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedHarness(harnessID):
            return "Chat harness \(harnessID) is not configured."
        }
    }
}

@MainActor
final class ChatHarnessRegistry {
    private let runtimesByID: [String: any ChatHarnessRuntime]

    init(runtimes: [any ChatHarnessRuntime]) {
        var mapped: [String: any ChatHarnessRuntime] = [:]
        for runtime in runtimes {
            mapped[runtime.harness.id] = runtime
        }
        runtimesByID = mapped
    }

    static func openCode(client: any OpenCodeManaging) -> ChatHarnessRegistry {
        ChatHarnessRegistry(runtimes: [OpenCodeHarnessRuntime(client: client)])
    }

    var availableHarnesses: [ChatHarness] {
        ChatHarness.allCases.filter { runtimesByID[$0.id] != nil }
    }

    func runtime(for harness: ChatHarness) throws -> any ChatHarnessRuntime {
        guard let runtime = runtimesByID[harness.id] else {
            throw ChatHarnessRegistryError.unsupportedHarness(harness.id)
        }
        return runtime
    }

    func runtime(forHarnessID harnessID: String) throws -> any ChatHarnessRuntime {
        guard let runtime = runtimesByID[harnessID] else {
            throw ChatHarnessRegistryError.unsupportedHarness(harnessID)
        }
        return runtime
    }

    func invalidateAll() {
        for runtime in runtimesByID.values {
            runtime.invalidate()
        }
    }
}
