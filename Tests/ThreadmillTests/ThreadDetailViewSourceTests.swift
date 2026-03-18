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
        XCTAssertTrue(source.contains("ToolbarItem(placement: .navigation)"))
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

    func testTerminalModeContentShowsDebugSummaryWhileConnecting() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/TerminalModeContent.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("terminal.debug.summary."))
        XCTAssertTrue(source.contains("appState.terminalDebugSnapshot(for: preset)"))
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
    }

    func testThreadDetailViewExposesAppAndLocalDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/ThreadDetailView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("automation.thread-detail-debug"))
        XCTAssertTrue(source.contains("automation.thread-detail-debug.json"))
        XCTAssertTrue(source.contains("appState.debugSnapshot().summary"))
        XCTAssertTrue(source.contains("selectedTab="))
    }

    func testAutomationControlsExposeJSONDebugSurfaces() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/AutomationControlsView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("automation.app-debug.json"))
        XCTAssertTrue(source.contains("automation.terminal-debug-json."))
        XCTAssertTrue(source.contains("debugJSONString(appState.debugSnapshot())"))
    }

    func testFileBrowserViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Files/FileBrowserView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("automation.file-browser-debug"))
        XCTAssertTrue(source.contains("automation.file-browser-debug.json"))
        XCTAssertTrue(source.contains("viewModel.debugSnapshot"))
        XCTAssertTrue(source.contains("snapshot.summary"))
    }

    func testChatViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("automation.chat-debug"))
        XCTAssertTrue(source.contains("automation.chat-debug.json"))
        XCTAssertTrue(source.contains("viewModel.debugSnapshot.summary"))
        XCTAssertTrue(source.contains("selectedConversationID="))
    }

    func testBrowserViewExposesDebugSummaryForAutomation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Browser/BrowserView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("automation.browser-debug"))
        XCTAssertTrue(source.contains("automation.browser-debug.json"))
        XCTAssertTrue(source.contains("manager.debugSummary"))
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
    }
}
