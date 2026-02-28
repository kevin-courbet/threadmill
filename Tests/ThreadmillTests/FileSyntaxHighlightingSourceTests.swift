import Foundation
import XCTest

final class FileSyntaxHighlightingSourceTests: XCTestCase {
    func testFileContentTabViewUsesCodeEditorView() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Files/FileContentTabView.swift")

        XCTAssertTrue(source.contains("CodeEditorView("))
        XCTAssertFalse(source.contains("Text(content)"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourcePath, encoding: .utf8)
    }
}
