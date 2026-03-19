import Foundation
import XCTest

final class ThreadDetailViewSourceTests: XCTestCase {
    func testThreadDetailViewDoesNotContainInlineHideOrCloseButtons() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("Button(\"Hide\")"))
        XCTAssertFalse(source.contains("Button(\"Close\", role: .destructive)"))
    }

    func testThreadDetailViewDoesNotRenderProjectThreadHeaderLine() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("projectName"))
        XCTAssertFalse(source.contains("\\(projectName) · \\(thread.name)"))
    }

    func testRestoreThreadStateFiltersPersistedTerminalSessionsAgainstAvailablePresets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("Set(appState.presets.map(\\.name))"))
        XCTAssertTrue(source.contains("persistedTerminalSessions = persistedTerminalSessions.filter"))
    }

    func testFileBrowserViewResetsIdentityWhenThreadChanges() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("FileBrowserView(rootPath: thread.worktreePath, fileService: fileService, connectionStatus: appState.connectionStatus)"))
    }

    func testThreadDetailToolbarUsesNativeToolbarItemsAndNoCustomToolbarRow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains(".toolbar {"))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .automatic)"))
        XCTAssertFalse(source.contains("private var toolbarRow: some View"))
    }

    func testThreadDetailViewUsesUnifiedToolbarWithoutNestedNavigationStack() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("NavigationStack {"))
        XCTAssertFalse(source.contains(".navigationTitle(thread.branch)"))
        XCTAssertFalse(source.contains(".toolbarTitleDisplayMode(.inline)"))
        XCTAssertFalse(source.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
        XCTAssertFalse(source.contains("ToolbarTitleVisibilityModifier"))
    }

    func testContentViewDoesNotDefineEmptyToolbar() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Views/ContentView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains(".toolbar {}"))
    }

    func testContentViewExposesGlobalAutomationSwitchers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Views/ContentView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"app\""))
    }

    func testTerminalModeContentShowsDebugSummaryWhileConnecting() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/TerminalModeContent.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"terminal-\\(preset)\""))
        XCTAssertTrue(source.contains("appState.terminalDebugSnapshot(for: preset)"))
    }

    func testThreadDetailViewExposesAppAndLocalDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"thread-detail\""))
    }

    func testThreadDetailUsesRealModeTabAccessibilityIdentifiers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("Picker(\"Mode\", selection: $selectedTab)"))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains(".accessibilityRepresentation"))
        XCTAssertTrue(source.contains("mode.tab.\\(tab.id)"))
    }

    func testFileBrowserViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Files/FileBrowserView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"file-browser\""))
        XCTAssertTrue(source.contains("viewModel.debugSnapshot"))
    }

    func testChatViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"chat\""))
        XCTAssertTrue(source.contains("viewModel.debugSnapshot"))
    }

    func testBrowserViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Browser/BrowserView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("DebugSnapshotWriter(name: \"browser\""))
        XCTAssertTrue(source.contains("manager.debugSnapshot"))
    }
}
