import XCTest
@testable import Threadmill

@MainActor
final class KeyboardShortcutTests: XCTestCase {
    func testSelectThreadByIndexUpdatesSelectedThreadID() {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [PresetConfig(name: "terminal", command: "$SHELL", cwd: nil)]
        )
        database.projects = [project]
        database.threads = [
            ThreadModel(
                id: "thread-1",
                projectId: project.id,
                name: "first",
                branch: "first",
                worktreePath: "/tmp/demo/first",
                status: .active,
                sourceType: "new_feature",
                createdAt: Date(timeIntervalSince1970: 1),
                tmuxSession: "tm_first",
                portOffset: 0
            ),
            ThreadModel(
                id: "thread-2",
                projectId: project.id,
                name: "second",
                branch: "second",
                worktreePath: "/tmp/demo/second",
                status: .active,
                sourceType: "new_feature",
                createdAt: Date(timeIntervalSince1970: 2),
                tmuxSession: "tm_second",
                portOffset: 20
            ),
        ]

        let appState = AppState()
        appState.configure(
            connectionManager: connection,
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        appState.selectThreadByIndex(1)

        XCTAssertEqual(appState.selectedThreadID, "thread-2")
    }

    func testPresetTabShortcutsCycleSelectedPreset() {
        let connection = MockDaemonConnection(state: .connected)
        let database = MockDatabaseManager()
        let sync = MockSyncService()
        let multiplexer = MockTerminalMultiplexer()

        let project = Project(
            id: "project-1",
            name: "demo",
            remotePath: "/tmp/demo",
            defaultBranch: "main",
            presets: [
                PresetConfig(name: "terminal", command: "$SHELL", cwd: nil),
                PresetConfig(name: "opencode", command: "opencode", cwd: nil),
                PresetConfig(name: "logs", command: "tail -f app.log", cwd: nil),
            ]
        )
        database.projects = [project]
        database.threads = [
            ThreadModel(
                id: "thread-1",
                projectId: project.id,
                name: "first",
                branch: "first",
                worktreePath: "/tmp/demo/first",
                status: .active,
                sourceType: "new_feature",
                createdAt: Date(timeIntervalSince1970: 1),
                tmuxSession: "tm_first",
                portOffset: 0
            )
        ]

        let appState = AppState()
        appState.configure(
            connectionManager: connection,
            databaseManager: database,
            syncService: sync,
            multiplexer: multiplexer
        )
        appState.reloadFromDatabase()

        XCTAssertEqual(appState.selectedPreset, "terminal")

        appState.nextPresetTab()
        XCTAssertEqual(appState.selectedPreset, "opencode")

        appState.nextPresetTab()
        XCTAssertEqual(appState.selectedPreset, "logs")

        appState.nextPresetTab()
        XCTAssertEqual(appState.selectedPreset, "terminal")

        appState.previousPresetTab()
        XCTAssertEqual(appState.selectedPreset, "logs")
    }
}
