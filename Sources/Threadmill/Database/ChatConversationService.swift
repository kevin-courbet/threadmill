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

    init(databaseManager: any DatabaseManaging) {
        self.databaseManager = databaseManager
    }

    func createConversation(threadID: String, directory _: String, agentType: String = "opencode") async throws -> ChatConversation {
        var conversation = ChatConversation(threadID: threadID)
        conversation.agentType = agentType
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
}
