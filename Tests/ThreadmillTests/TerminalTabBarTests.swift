import XCTest
@testable import Threadmill

final class TerminalTabBarTests: XCTestCase {
    func testPreferredPresetToStartUsesTerminalBeforeFirstAvailable() {
        let presets = [
            Preset(name: "opencode", label: "Opencode"),
            Preset(name: "terminal", label: "Terminal"),
            Preset(name: "logs", label: "Logs"),
        ]

        XCTAssertEqual(preferredPresetToStart(from: presets)?.name, "terminal")
        XCTAssertEqual(preferredPresetToStart(from: [Preset(name: "logs", label: "Logs")])?.name, "logs")
        XCTAssertNil(preferredPresetToStart(from: []))
    }

    func testPreferredPresetToStartMatchesDefaultsCaseInsensitively() {
        let presets = [
            Preset(name: "opencode", label: "Opencode"),
            Preset(name: "Terminal", label: "Terminal"),
        ]

        XCTAssertEqual(preferredPresetToStart(from: presets)?.name, "Terminal")
    }

    func testChatTabIsClosable() {
        let chatTab = TerminalTabModel(threadID: "thread-1", type: .chat, endpoint: nil)

        XCTAssertTrue(chatTab.isClosable)
    }

    func testTerminalTabBarUsesStableCloseButtonLayoutInSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/TerminalTabs/TerminalTabBar.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("if showsClose"))
        XCTAssertTrue(source.contains(".opacity("))
        XCTAssertTrue(source.contains(".frame(minWidth:"))
    }
}
