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

        XCTAssertTrue(source.contains("FileBrowserView(rootPath: thread.worktreePath, fileService: fileService)\n                    .id(thread.id)"))
    }
}
