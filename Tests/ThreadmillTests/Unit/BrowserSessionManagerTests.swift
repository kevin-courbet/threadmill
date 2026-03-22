import XCTest
@testable import Threadmill

@MainActor
final class BrowserSessionManagerTests: XCTestCase {
    func testCreateCloseAndSwitchSessionsPersistsState() {
        let database = MockDatabaseManager()
        let thread = ThreadModel(
            id: "thread-1",
            projectId: "project-1",
            name: "feature-browser",
            branch: "feature-browser",
            worktreePath: "/tmp/thread-1",
            status: .active,
            sourceType: "new_feature",
            createdAt: Date(timeIntervalSince1970: 1),
            tmuxSession: "tmux-1",
            portOffset: 40
        )

        let manager = BrowserSessionManager(databaseManager: database, thread: thread)

        XCTAssertTrue(manager.sessions.isEmpty)

        manager.createSession()
        let firstSessionID = try! XCTUnwrap(manager.activeSessionId)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.currentURL, "http://localhost:3040")

        manager.createSession()
        let secondSessionID = try! XCTUnwrap(manager.activeSessionId)
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertEqual(manager.sessions.count, 2)

        manager.handleURLChange(sessionID: secondSessionID, url: "https://swift.org")
        manager.handleTitleChange(sessionID: secondSessionID, title: "Swift")
        manager.selectSession(firstSessionID)

        XCTAssertEqual(manager.activeSessionId, firstSessionID)
        XCTAssertEqual(manager.currentURL, "http://localhost:3040")

        manager.closeSession(firstSessionID)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.activeSessionId, secondSessionID)
        XCTAssertEqual(manager.currentURL, "https://swift.org")
        XCTAssertEqual(database.browserSessions.filter { $0.threadID == thread.id }.count, 1)
    }
}
