import Foundation

enum ChatConversationServiceError: LocalizedError {
    case conversationNotFound(String)
    case threadNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .conversationNotFound(id):
            return "Conversation \(id) was not found."
        case let .threadNotFound(id):
            return "Thread \(id) was not found."
        }
    }
}

@MainActor
final class ChatConversationService: ChatConversationManaging {
    private let databaseManager: any DatabaseManaging
    private let chatHarnessRegistry: ChatHarnessRegistry

    init(databaseManager: any DatabaseManaging, chatHarnessRegistry: ChatHarnessRegistry) {
        self.databaseManager = databaseManager
        self.chatHarnessRegistry = chatHarnessRegistry
    }

    func createConversation(threadID: String, directory: String, harness: ChatHarness) async throws -> ChatConversation {
        let runtime = try chatHarnessRegistry.runtime(for: harness)
        var conversation = ChatConversation(threadID: threadID, harness: harness)
        let session = try await runtime.createSession(directory: directory)
        conversation.linkSession(session.id)
        try databaseManager.saveConversation(conversation)
        return conversation
    }

    func listConversations(threadID: String) async throws -> [ChatConversation] {
        try databaseManager.listConversations(threadID: threadID)
    }

    func activeConversations(threadID: String) async throws -> [ChatConversation] {
        try databaseManager.activeConversations(threadID: threadID)
    }

    func archiveConversation(id: String) async throws {
        guard var conversation = try databaseManager.conversation(id: id) else {
            throw ChatConversationServiceError.conversationNotFound(id)
        }

        conversation.archive()
        try databaseManager.saveConversation(conversation)
    }

    func updateTitle(conversationID: String, title: String) async throws {
        guard var conversation = try databaseManager.conversation(id: conversationID) else {
            throw ChatConversationServiceError.conversationNotFound(conversationID)
        }

        conversation.updateTitle(title)
        try databaseManager.saveConversation(conversation)
    }

    func verifySession(conversation: ChatConversation) async throws -> Bool {
        guard let sessionID = conversation.sessionID else {
            return false
        }

        guard let harness = conversation.harness else {
            throw ChatHarnessRegistryError.unsupportedHarness(conversation.harnessID)
        }

        let runtime = try chatHarnessRegistry.runtime(for: harness)

        guard let directory = try databaseManager.allThreads().first(where: { $0.id == conversation.threadID })?.worktreePath else {
            throw ChatConversationServiceError.threadNotFound(conversation.threadID)
        }

        do {
            _ = try await runtime.getSession(id: sessionID, directory: directory)
            return true
        } catch {
            return false
        }
    }
}
