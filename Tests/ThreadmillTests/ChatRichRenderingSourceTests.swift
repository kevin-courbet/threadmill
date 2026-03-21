import Foundation
import XCTest

final class ChatRichRenderingSourceTests: XCTestCase {
    func testChatMessageListUsesRichRenderingViews() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatMessageList.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("ToolCallView"))
        XCTAssertTrue(source.contains("ToolCallGroupView"))
        XCTAssertTrue(source.contains("TurnSummaryView"))
        XCTAssertFalse(source.contains("rendering arrives in Phase 5"))
    }
}
