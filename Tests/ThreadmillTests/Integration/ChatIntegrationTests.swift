import ACPModel
import XCTest
@testable import Threadmill

final class ChatIntegrationTests: IntegrationTestCase {
    func testACPAgentSendReceive() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let (channelID, sessionID) = try await startACPSession(conn: conn)

        let promptRequest = try makeACPRequest(
            id: 3,
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(sessionID),
                prompt: [.text(TextContent(text: "What is 2+2?"))]
            )
        )
        try await conn.sendBinary(makeACPFrame(channelID: channelID, payload: promptRequest))

        let update = try await waitForACPLine(conn: conn, channelID: channelID, timeout: 10) { line in
            guard line["method"] as? String == "session/update" else { return false }
            return Self.findTextInJSON(line)
        }
        XCTAssertEqual(update["method"] as? String, "session/update")
    }

    func testChatConversationEndToEnd() async throws {
        let conn = try await makeConnection()
        defer { conn.disconnect() }

        let (channelID, acpSessionID) = try await startACPSession(conn: conn)

        let dbPath = try makeTempDatabasePath()
        let conversation = try await createAndLinkConversation(
            dbPath: dbPath, acpSessionID: acpSessionID
        )

        let promptReq = try makeACPRequest(
            id: 3,
            method: "session/prompt",
            params: SessionPromptRequest(
                sessionId: SessionId(acpSessionID),
                prompt: [.text(TextContent(text: "Reply with just the word 'hello'. Nothing else."))]
            )
        )
        try await conn.sendBinary(makeACPFrame(channelID: channelID, payload: promptReq))

        let update = try await waitForACPLine(conn: conn, channelID: channelID, timeout: 10) { line in
            guard line["method"] as? String == "session/update" else { return false }
            return Self.findTextInJSON(line)
        }
        XCTAssertEqual(update["method"] as? String, "session/update")

        let active = try await verifyConversation(dbPath: dbPath)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, conversation.id)
        XCTAssertEqual(active.first?.agentType, "opencode")
        XCTAssertEqual(active.first?.agentSessionID, acpSessionID)
    }

    // MARK: - GRDB helpers

    @MainActor
    private func createAndLinkConversation(dbPath: String, acpSessionID: String) throws -> ChatConversation {
        let database = try DatabaseManager(databasePath: dbPath)
        var conv = ChatConversation(threadID: "test-thread")
        conv.agentType = "opencode"
        conv.agentSessionID = acpSessionID
        try database.saveConversation(conv)
        return conv
    }

    @MainActor
    private func verifyConversation(dbPath: String) throws -> [ChatConversation] {
        let database = try DatabaseManager(databasePath: dbPath)
        return try database.activeConversations(threadID: "test-thread")
    }
}
