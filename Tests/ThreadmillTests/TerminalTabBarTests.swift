import XCTest
@testable import Threadmill

final class TerminalTabBarTests: XCTestCase {
    func testAddButtonAlwaysVisibleAndHardcodedToTerminalInSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/TerminalTabs/TerminalTabBar.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertFalse(source.contains("if !availablePresets.isEmpty"))
        XCTAssertTrue(source.contains("onAdd(\"terminal\")"))
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
