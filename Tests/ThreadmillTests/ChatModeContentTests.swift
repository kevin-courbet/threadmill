import XCTest
@testable import Threadmill

@MainActor
final class ChatModeContentTests: XCTestCase {
    func testViewModelCacheReusesViewModelWhenConversationIsUnchanged() {
        let cache = ChatSessionViewModelCache()
        var createCount = 0

        let first = cache.resolve(conversationID: "conversation-1") {
            createCount += 1
            return ChatSessionViewModel(agentSessionManager: nil, sessionID: "session-1", threadID: "thread-1")
        }

        let second = cache.resolve(conversationID: "conversation-1") {
            createCount += 1
            return ChatSessionViewModel(agentSessionManager: nil, sessionID: "session-1", threadID: "thread-1")
        }

        XCTAssertTrue(first === second)
        XCTAssertEqual(createCount, 1)
    }

    func testViewModelCacheRecreatesViewModelWhenConversationChanges() {
        let cache = ChatSessionViewModelCache()
        var createCount = 0

        let first = cache.resolve(conversationID: "conversation-1") {
            createCount += 1
            return ChatSessionViewModel(agentSessionManager: nil, sessionID: "session-1", threadID: "thread-1")
        }

        let second = cache.resolve(conversationID: "conversation-2") {
            createCount += 1
            return ChatSessionViewModel(agentSessionManager: nil, sessionID: "session-2", threadID: "thread-1")
        }

        XCTAssertFalse(first === second)
        XCTAssertEqual(createCount, 2)
    }
}
