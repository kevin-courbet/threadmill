import Foundation
import XCTest

/// Tests the new preset behavior:
/// - The + button creates unlimited terminal sessions (each is a fresh shell)
/// - The dropdown menu offers named presets like dev-server (one instance per named preset)
/// - Each terminal session sends preset.start + terminal.attach to the daemon
@MainActor
final class TerminalPresetBehaviorTests: XCTestCase {

    // MARK: - Test 1: + button creates 3 independent terminals

    func testPlusButtonCreatesThreeTerminals() throws {
        let fixture = singleProjectFixture()
        let threadID = fixture[0].thread.id
        let harness = try UITestHarness.launch(with: fixture)
        defer { harness.tearDown() }

        // Switch to Terminal mode
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        // The first terminal is auto-created when switching to terminal mode
        let firstStart = try harness.waitForRequest(method: "preset.start", index: 0, timeout: 15)
        XCTAssertEqual(firstStart["thread_id"] as? String, threadID)
        XCTAssertEqual(firstStart["preset"] as? String, "terminal")
        _ = try harness.waitForRequest(method: "terminal.attach", index: 0, timeout: 15)

        // Click + to create second terminal
        try harness.click(identifier: "terminal.session.add")
        let secondStart = try harness.waitForRequest(method: "preset.start", index: 1, timeout: 15)
        XCTAssertEqual(secondStart["thread_id"] as? String, threadID)
        XCTAssertEqual(secondStart["preset"] as? String, "terminal",
                       "+ button should create another terminal, not a different preset")
        _ = try harness.waitForRequest(method: "terminal.attach", index: 1, timeout: 15)

        // Click + to create third terminal
        try harness.click(identifier: "terminal.session.add")
        let thirdStart = try harness.waitForRequest(method: "preset.start", index: 2, timeout: 15)
        XCTAssertEqual(thirdStart["thread_id"] as? String, threadID)
        XCTAssertEqual(thirdStart["preset"] as? String, "terminal",
                       "+ button should always create terminals, never cycle through presets")
        _ = try harness.waitForRequest(method: "terminal.attach", index: 2, timeout: 15)

        // Verify: 3 preset.start calls, all for "terminal"
        let allStarts = harness.server.requestParams(method: "preset.start")
        XCTAssertEqual(allStarts.count, 3)
        XCTAssertTrue(allStarts.allSatisfy { ($0["preset"] as? String) == "terminal" },
                      "All 3 sessions should be terminal presets")

        // Verify: 3 terminal.attach calls
        let allAttaches = harness.server.requestParams(method: "terminal.attach")
        XCTAssertEqual(allAttaches.count, 3)
    }

    // MARK: - Test 2: Dropdown opens dev-server named preset

    func testDropdownOpensDevServer() throws {
        let fixture = singleProjectFixture()
        let threadID = fixture[0].thread.id
        let harness = try UITestHarness.launch(with: fixture)
        defer { harness.tearDown() }

        // Switch to Terminal mode — first terminal auto-starts
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")
        _ = try harness.waitForRequest(method: "preset.start", index: 0, timeout: 15)
        _ = try harness.waitForRequest(method: "terminal.attach", index: 0, timeout: 15)

        // Click the dropdown menu on the + button and select dev-server
        try harness.click(identifier: "terminal.session.add.menu")
        try harness.clickTitledElement("Dev Server")

        let devServerStart = try harness.waitForRequest(method: "preset.start", index: 1, timeout: 15)
        XCTAssertEqual(devServerStart["thread_id"] as? String, threadID)
        XCTAssertEqual(devServerStart["preset"] as? String, "dev-server")

        let devServerAttach = try harness.waitForRequest(method: "terminal.attach", index: 1, timeout: 15)
        XCTAssertEqual(devServerAttach["thread_id"] as? String, threadID)
        XCTAssertEqual(devServerAttach["preset"] as? String, "dev-server")

        // Verify final state: 1 terminal + 1 dev-server
        let allStarts = harness.server.requestParams(method: "preset.start")
        XCTAssertEqual(allStarts.count, 2)
        XCTAssertEqual(allStarts[0]["preset"] as? String, "terminal")
        XCTAssertEqual(allStarts[1]["preset"] as? String, "dev-server")
    }

    // MARK: - Fixtures

    private func singleProjectFixture() -> [MockSpindleServer.ProjectFixture] {
        let suffix = UUID().uuidString.lowercased()
        return [
            MockSpindleServer.ProjectFixture(
                id: "project-\(suffix)",
                name: "myapp",
                path: "/home/wsl/dev/myapp",
                presets: [
                    MockSpindleServer.PresetFixture(name: "terminal", command: "$SHELL"),
                    MockSpindleServer.PresetFixture(name: "dev-server", command: "task dev:worktree"),
                ],
                thread: MockSpindleServer.ThreadFixture(
                    id: "thread-\(suffix)",
                    name: "feature-work",
                    branch: "feature/work",
                    worktreePath: "/home/wsl/dev/.threadmill/myapp/feature-work",
                    createdAt: Date(timeIntervalSince1970: 1),
                    tmuxSession: "tm_myapp_work"
                ),
                repo: MockSpindleServer.RepoFixture(
                    id: "repo-\(suffix)",
                    owner: "myorg",
                    name: "myapp",
                    fullName: "myorg/myapp",
                    cloneURL: "git@github.com:myorg/myapp.git"
                )
            ),
        ]
    }
}
