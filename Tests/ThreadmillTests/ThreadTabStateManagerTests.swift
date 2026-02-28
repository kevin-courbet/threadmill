import XCTest
@testable import Threadmill

@MainActor
final class ThreadTabStateManagerTests: XCTestCase {
    func testModeSwitchingUsesVisibleModesForShortcutsAndCycling() {
        let visibleModeIDs = ["chat", "terminal", "browser"]

        XCTAssertEqual(ThreadTabStateManager.modeIDForShortcut(index: 1, visibleModeIDs: visibleModeIDs), "chat")
        XCTAssertEqual(ThreadTabStateManager.modeIDForShortcut(index: 2, visibleModeIDs: visibleModeIDs), "terminal")
        XCTAssertEqual(ThreadTabStateManager.modeIDForShortcut(index: 3, visibleModeIDs: visibleModeIDs), "browser")
        XCTAssertNil(ThreadTabStateManager.modeIDForShortcut(index: 4, visibleModeIDs: visibleModeIDs))

        XCTAssertEqual(ThreadTabStateManager.nextModeID(after: "chat", visibleModeIDs: visibleModeIDs), "terminal")
        XCTAssertEqual(ThreadTabStateManager.nextModeID(after: "browser", visibleModeIDs: visibleModeIDs), "chat")
        XCTAssertEqual(ThreadTabStateManager.previousModeID(before: "chat", visibleModeIDs: visibleModeIDs), "browser")
    }

    func testStatePersistsSelectedModeAndSessionIDsPerThread() {
        let suiteName = "ThreadTabStateManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Expected isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "thread.tab-state.tests"
        let manager = ThreadTabStateManager(defaults: defaults, storageKey: storageKey)

        manager.setSelectedMode("terminal", threadID: "thread-1")
        manager.setSelectedSessionID("terminal", modeID: "terminal", threadID: "thread-1")
        manager.setSelectedSessionID("conv-42", modeID: "chat", threadID: "thread-1")
        manager.setTerminalSessionIDs(["terminal", "logs"], threadID: "thread-1")

        let restored = ThreadTabStateManager(defaults: defaults, storageKey: storageKey)

        XCTAssertEqual(restored.selectedMode(threadID: "thread-1"), "terminal")
        XCTAssertEqual(restored.selectedSessionID(modeID: "terminal", threadID: "thread-1"), "terminal")
        XCTAssertEqual(restored.selectedSessionID(modeID: "chat", threadID: "thread-1"), "conv-42")
        XCTAssertEqual(restored.terminalSessionIDs(threadID: "thread-1"), ["terminal", "logs"])
        XCTAssertEqual(restored.selectedMode(threadID: "thread-2"), "chat")
    }
}
