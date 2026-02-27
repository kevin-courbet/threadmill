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
}
