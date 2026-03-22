import Foundation
import XCTest

final class SettingsWindowSourceTests: XCTestCase {
    func testSettingsWindowMatchesAizenArchitectureAndCommandShortcut() throws {
        let managerSource = try loadSource(at: "Sources/Threadmill/App/SettingsWindowManager.swift")
        XCTAssertTrue(managerSource.contains("static let shared = SettingsWindowManager()"))
        XCTAssertTrue(managerSource.contains("func show"))
        XCTAssertTrue(managerSource.contains("NSHostingController(rootView:"))
        XCTAssertTrue(managerSource.contains("window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]"))
        XCTAssertTrue(managerSource.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(managerSource.contains("window.toolbarStyle = .unified"))
        XCTAssertTrue(managerSource.contains("window.setContentSize(NSSize(width: 700, height: 500))"))
        XCTAssertTrue(managerSource.contains("window.minSize = NSSize(width: 650, height: 400)"))

        let viewSource = try loadSource(at: "Sources/Threadmill/Features/Settings/SettingsView.swift")
        XCTAssertTrue(viewSource.contains("NavigationSplitView"))
        XCTAssertTrue(viewSource.contains("List(selection: $selectedSection)"))
        XCTAssertTrue(viewSource.contains("enum SettingsSection: Hashable"))
        XCTAssertTrue(viewSource.contains("case general"))
        XCTAssertTrue(viewSource.contains("case remotes"))
        XCTAssertTrue(viewSource.contains("case chat"))
        XCTAssertTrue(viewSource.contains(".toolbar(removing: .sidebarToggle)"))

        let generalSource = try loadSource(at: "Sources/Threadmill/Features/Settings/GeneralSettingsView.swift")
        XCTAssertTrue(generalSource.contains("@AppStorage(\"editorFontSize\")"))
        XCTAssertTrue(generalSource.contains("@AppStorage(\"editorWrapLines\")"))
        XCTAssertTrue(generalSource.contains("@AppStorage(\"threadmill.show-chat-tab\")"))
        XCTAssertTrue(generalSource.contains("@AppStorage(\"threadmill.show-terminal-tab\")"))
        XCTAssertTrue(generalSource.contains("@AppStorage(\"threadmill.show-files-tab\")"))
        XCTAssertTrue(generalSource.contains("@AppStorage(\"threadmill.show-browser-tab\")"))
        XCTAssertTrue(generalSource.contains(".formStyle(.grouped)"))

        let remotesSource = try loadSource(at: "Sources/Threadmill/Features/Settings/RemotesSettingsView.swift")
        XCTAssertTrue(remotesSource.contains(".formStyle(.grouped)"))
        XCTAssertTrue(remotesSource.contains("saveRemote"))
        XCTAssertTrue(remotesSource.contains("deleteRemote"))

        let chatSource = try loadSource(at: "Sources/Threadmill/Features/Settings/ChatSettingsView.swift")
        XCTAssertTrue(chatSource.contains("GitHub"))
        XCTAssertTrue(chatSource.contains(".formStyle(.grouped)"))

        let appSource = try loadSource(at: "Sources/Threadmill/App/ThreadmillApp.swift")
        XCTAssertTrue(appSource.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(appSource.contains(".keyboardShortcut(\",\", modifiers: .command)"))
        XCTAssertTrue(appSource.contains("SettingsWindowManager.shared.show"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            let sourcePath = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }
}
