import Foundation
import XCTest

@MainActor
final class TerminalCreationTests: XCTestCase {
    func testCreatesPresetTerminalsAcrossTwoProjects() throws {
        let fixture = validationFixture()
        let projectAThreadID = fixture[0].thread.id
        let projectBThreadID = fixture[1].thread.id
        let harness = try UITestHarness.launch(with: fixture)
        defer { harness.tearDown() }

        // --- Project A ---
        _ = try harness.waitForElement(identifier: "thread.row.\(projectAThreadID)")
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        // Wait for project A's first terminal to start
        _ = try harness.waitForRequestWhere(method: "preset.start", timeout: 15) {
            ($0["thread_id"] as? String) == projectAThreadID && ($0["preset"] as? String) == "terminal"
        }
        _ = try harness.waitForRequestWhere(method: "terminal.attach", timeout: 15) {
            ($0["thread_id"] as? String) == projectAThreadID
        }
        let startsAfterA1 = harness.server.requestParams(method: "preset.start").count

        // Create second terminal for project A via + button
        try harness.click(identifier: "terminal.session.add")
        try harness.waitForRequestCount(method: "preset.start", count: startsAfterA1 + 1, timeout: 15)

        let projectAStarts = harness.server.requestParams(method: "preset.start").filter {
            ($0["thread_id"] as? String) == projectAThreadID
        }
        XCTAssertGreaterThanOrEqual(projectAStarts.count, 2,
                                    "Project A should have at least 2 terminal starts")

        // --- Switch to Project B ---
        try harness.click(identifier: "thread.row.\(projectBThreadID)")
        // Wait for chat mode to settle (thread switch resets to chat)
        _ = try harness.waitForElement(identifier: "chat.session.add")
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        // Wait for project B's first terminal to start
        _ = try harness.waitForRequestWhere(method: "preset.start", timeout: 15) {
            ($0["thread_id"] as? String) == projectBThreadID && ($0["preset"] as? String) == "terminal"
        }
        let startsAfterB1 = harness.server.requestParams(method: "preset.start").count

        // Create second terminal for project B via + button
        try harness.click(identifier: "terminal.session.add")
        try harness.waitForRequestCount(method: "preset.start", count: startsAfterB1 + 1, timeout: 15)

        let projectBStarts = harness.server.requestParams(method: "preset.start").filter {
            ($0["thread_id"] as? String) == projectBThreadID
        }
        XCTAssertGreaterThanOrEqual(projectBStarts.count, 2,
                                    "Project B should have at least 2 terminal starts")

        // --- Verify cross-project correctness ---
        // Both projects should have independent terminal starts
        XCTAssertTrue(projectAStarts.allSatisfy { ($0["preset"] as? String) == "terminal" })
        XCTAssertTrue(projectBStarts.allSatisfy { ($0["preset"] as? String) == "terminal" })

        // Total attaches should cover both projects
        let projectAAttaches = harness.server.requestParams(method: "terminal.attach").filter {
            ($0["thread_id"] as? String) == projectAThreadID
        }
        let projectBAttaches = harness.server.requestParams(method: "terminal.attach").filter {
            ($0["thread_id"] as? String) == projectBThreadID
        }
        XCTAssertGreaterThanOrEqual(projectAAttaches.count, 2, "Project A should have at least 2 attaches")
        XCTAssertGreaterThanOrEqual(projectBAttaches.count, 2, "Project B should have at least 2 attaches")
    }

    private func validationFixture() -> [MockSpindleServer.ProjectFixture] {
        let suffix = UUID().uuidString.lowercased()
        let projectAID = "project-a-\(suffix)"
        let projectBID = "project-b-\(suffix)"
        let threadAID = "thread-project-a-\(suffix)"
        let threadBID = "thread-project-b-\(suffix)"
        let presets = [
            MockSpindleServer.PresetFixture(name: "terminal", command: "bash"),
            MockSpindleServer.PresetFixture(name: "dev-server", command: "task dev:worktree"),
        ]

        return [
            MockSpindleServer.ProjectFixture(
                id: projectAID,
                name: "Project A",
                path: "/home/wsl/dev/project-a",
                presets: presets,
                thread: MockSpindleServer.ThreadFixture(
                    id: threadAID,
                    name: "project-a-thread",
                    branch: "feature/project-a",
                    worktreePath: "/home/wsl/dev/.threadmill/project-a/project-a-thread",
                    createdAt: Date(timeIntervalSince1970: 2),
                    tmuxSession: "tm_project_a"
                ),
                repo: MockSpindleServer.RepoFixture(
                    id: "repo-project-a-\(suffix)",
                    owner: "threadmill",
                    name: "project-a",
                    fullName: "threadmill/project-a",
                    cloneURL: "git@github.com:threadmill/project-a.git"
                )
            ),
            MockSpindleServer.ProjectFixture(
                id: projectBID,
                name: "Project B",
                path: "/home/wsl/dev/project-b",
                presets: presets,
                thread: MockSpindleServer.ThreadFixture(
                    id: threadBID,
                    name: "project-b-thread",
                    branch: "feature/project-b",
                    worktreePath: "/home/wsl/dev/.threadmill/project-b/project-b-thread",
                    createdAt: Date(timeIntervalSince1970: 1),
                    tmuxSession: "tm_project_b"
                ),
                repo: MockSpindleServer.RepoFixture(
                    id: "repo-project-b-\(suffix)",
                    owner: "threadmill",
                    name: "project-b",
                    fullName: "threadmill/project-b",
                    cloneURL: "git@github.com:threadmill/project-b.git"
                )
            ),
        ]
    }
}
