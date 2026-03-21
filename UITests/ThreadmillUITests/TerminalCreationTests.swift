import Foundation
import XCTest

final class TerminalCreationTests: XCTestCase {
    func testCreatesPresetTerminalsAcrossTwoProjects() throws {
        let fixture = validationFixture()
        let projectAThreadID = fixture[0].thread.id
        let projectBThreadID = fixture[1].thread.id
        let harness = try UITestHarness.launch(with: fixture)
        defer { harness.tearDown() }

        _ = try harness.waitForElement(identifier: "thread.row.\(projectAThreadID)")
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        let firstStart = try harness.waitForRequest(method: "preset.start", index: 0, timeout: 15)
        XCTAssertEqual(firstStart["thread_id"] as? String, projectAThreadID)
        XCTAssertEqual(firstStart["preset"] as? String, "terminal")

        let firstAttach = try harness.waitForRequest(method: "terminal.attach", index: 0, timeout: 15)
        XCTAssertEqual(firstAttach["thread_id"] as? String, projectAThreadID)
        XCTAssertEqual(firstAttach["preset"] as? String, "terminal")

        try harness.click(identifier: "terminal.session.add")

        let secondStart = try harness.waitForRequest(method: "preset.start", index: 1, timeout: 15)
        XCTAssertEqual(secondStart["thread_id"] as? String, projectAThreadID)
        XCTAssertEqual(secondStart["preset"] as? String, "dev-server")

        let secondAttach = try harness.waitForRequest(method: "terminal.attach", index: 1, timeout: 15)
        XCTAssertEqual(secondAttach["thread_id"] as? String, projectAThreadID)
        XCTAssertEqual(secondAttach["preset"] as? String, "dev-server")

        try harness.click(identifier: "thread.row.\(projectBThreadID)")
        _ = try harness.waitForElement(identifier: "chat.session.add")
        try harness.clickMode(identifier: "mode.tab.terminal", label: "Terminal")

        let thirdStart = try harness.waitForRequest(method: "preset.start", index: 2, timeout: 15)
        XCTAssertEqual(thirdStart["thread_id"] as? String, projectBThreadID)
        XCTAssertEqual(thirdStart["preset"] as? String, "terminal")

        let thirdAttach = try harness.waitForRequest(method: "terminal.attach", index: 2, timeout: 15)
        XCTAssertEqual(thirdAttach["thread_id"] as? String, projectBThreadID)
        XCTAssertEqual(thirdAttach["preset"] as? String, "terminal")

        try harness.click(identifier: "terminal.session.add")

        let fourthStart = try harness.waitForRequest(method: "preset.start", index: 3, timeout: 15)
        XCTAssertEqual(fourthStart["thread_id"] as? String, projectBThreadID)
        XCTAssertEqual(fourthStart["preset"] as? String, "dev-server")

        let fourthAttach = try harness.waitForRequest(method: "terminal.attach", index: 3, timeout: 15)
        XCTAssertEqual(fourthAttach["thread_id"] as? String, projectBThreadID)
        XCTAssertEqual(fourthAttach["preset"] as? String, "dev-server")

        let presetStarts = harness.server.requestParams(method: "preset.start")
        XCTAssertEqual(presetStarts.count, 4)
        XCTAssertEqual(
            presetStarts.map { "\(($0["thread_id"] as? String) ?? ""):\(($0["preset"] as? String) ?? "")" },
            [
                "\(projectAThreadID):terminal",
                "\(projectAThreadID):dev-server",
                "\(projectBThreadID):terminal",
                "\(projectBThreadID):dev-server",
            ]
        )

        let terminalAttaches = harness.server.requestParams(method: "terminal.attach")
        XCTAssertEqual(terminalAttaches.count, 4)
        XCTAssertEqual(
            terminalAttaches.map { "\(($0["thread_id"] as? String) ?? ""):\(($0["preset"] as? String) ?? "")" },
            [
                "\(projectAThreadID):terminal",
                "\(projectAThreadID):dev-server",
                "\(projectBThreadID):terminal",
                "\(projectBThreadID):dev-server",
            ]
        )
    }

    private func validationFixture() -> [MockSpindleServer.ProjectFixture] {
        let suffix = UUID().uuidString.lowercased()
        let projectAID = "project-a-\(suffix)"
        let projectBID = "project-b-\(suffix)"
        let threadAID = "thread-project-a-\(suffix)"
        let threadBID = "thread-project-b-\(suffix)"
        let presets = [
            MockSpindleServer.PresetFixture(name: "terminal", command: "bash"),
            MockSpindleServer.PresetFixture(name: "dev-server", command: "bun run dev"),
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
