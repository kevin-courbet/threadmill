import Foundation
import XCTest

final class ChatViewSourceTests: XCTestCase {
    func testJumpToLatestVisibilityDependsOnIsNearBottom() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var isNearBottom = true"))
        XCTAssertTrue(source.contains("!isNearBottom"))
    }
}
