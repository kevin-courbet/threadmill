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

        // Switch to Terminal mode — this starts terminal-1
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        // Wait for the initial terminal to be fully started and attached
        let baselineStart = try harness.waitForRequestWhere(method: "preset.start", timeout: 15) {
            ($0["thread_id"] as? String) == threadID && ($0["preset"] as? String) == "terminal"
        }
        XCTAssertNotNil(baselineStart)
        let startsAfterFirst = harness.server.requestParams(method: "preset.start").count
        let attachesAfterFirst = harness.server.requestParams(method: "terminal.attach").count

        // Click + to create second terminal
        try harness.click(identifier: "terminal.session.add")
        try harness.waitForRequestCount(method: "preset.start", count: startsAfterFirst + 1, timeout: 15)

        // Click + to create third terminal
        try harness.click(identifier: "terminal.session.add")
        try harness.waitForRequestCount(method: "preset.start", count: startsAfterFirst + 2, timeout: 15)

        // Verify: + button created terminals, not other presets
        let startsAfterPlus = harness.server.requestParams(method: "preset.start").suffix(from: startsAfterFirst)
        XCTAssertTrue(startsAfterPlus.allSatisfy { ($0["preset"] as? String) == "terminal" },
                      "+ button should always create terminals")
        XCTAssertEqual(startsAfterPlus.count, 2, "2 additional terminals from + clicks")

        // Verify: corresponding attaches happened
        let totalAttaches = harness.server.requestParams(method: "terminal.attach").count
        XCTAssertGreaterThanOrEqual(totalAttaches, attachesAfterFirst + 2)
    }

    // MARK: - Test 2: Dropdown opens dev-server named preset

    func testDropdownOpensDevServer() throws {
        let fixture = singleProjectFixture()
        let threadID = fixture[0].thread.id
        let harness = try UITestHarness.launch(with: fixture)
        defer { harness.tearDown() }

        // Switch to Terminal mode — first terminal auto-starts
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")
        _ = try harness.waitForRequestWhere(method: "preset.start", timeout: 15) {
            ($0["preset"] as? String) == "terminal"
        }
        let startsBaseline = harness.server.requestParams(method: "preset.start").count

        // Open the dropdown menu and select dev-server
        try harness.click(identifier: "terminal.session.add.menu")
        Thread.sleep(forTimeInterval: 0.5)
        try harness.click(identifier: "terminal.session.add.item.dev-server")

        // Wait for dev-server to start
        let devServerStart = try harness.waitForRequestWhere(method: "preset.start", timeout: 15) {
            ($0["preset"] as? String) == "dev-server"
        }
        XCTAssertEqual(devServerStart["thread_id"] as? String, threadID)

        // Verify dev-server was attached
        let devServerAttach = try harness.waitForRequestWhere(method: "terminal.attach", timeout: 15) {
            ($0["preset"] as? String) == "dev-server"
        }
        XCTAssertEqual(devServerAttach["thread_id"] as? String, threadID)

        // Verify: exactly 1 new start for dev-server after baseline
        let newStarts = harness.server.requestParams(method: "preset.start").suffix(from: startsBaseline)
        XCTAssertEqual(newStarts.count, 1)
        XCTAssertEqual(newStarts.first?["preset"] as? String, "dev-server")
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
