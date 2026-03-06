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
    private let openCodeClient: any OpenCodeManaging

    init(databaseManager: any DatabaseManaging, openCodeClient: any OpenCodeManaging) {
        self.databaseManager = databaseManager
        self.openCodeClient = openCodeClient
    }

    func createConversation(threadID: String, directory: String, agentID: String?, model: OCMessageModel?) async throws -> ChatConversation {
        var conversation = ChatConversation(threadID: threadID)
        try databaseManager.saveConversation(conversation)

        let session = try await openCodeClient.createSession(directory: directory, agentID: agentID)
        let initializedSession = try await openCodeClient.initSession(id: session.id, directory: directory, model: model)
        conversation.linkSession(initializedSession.id)
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
        guard let sessionID = conversation.opencodeSessionID else {
            return false
        }

        guard let directory = try databaseManager.allThreads().first(where: { $0.id == conversation.threadID })?.worktreePath else {
            throw ChatConversationServiceError.threadNotFound(conversation.threadID)
        }

        do {
            _ = try await openCodeClient.getSession(id: sessionID, directory: directory)
            return true
        } catch {
            return false
        }
    }
}
