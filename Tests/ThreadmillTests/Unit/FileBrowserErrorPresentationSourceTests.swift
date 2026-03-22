import Foundation
import XCTest

final class FileBrowserErrorPresentationSourceTests: XCTestCase {
    func testFileTreeViewShowsInlineErrorAndRetryAction() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Files/FileTreeView.swift")

        XCTAssertTrue(source.contains("viewModel.lastErrorMessage"))
        XCTAssertTrue(source.contains("ContentUnavailableView"))
        XCTAssertTrue(source.contains("Retry"))
    }

    func testFileContentTabViewShowsReadErrorAndRetryAction() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Files/FileContentTabView.swift")

        XCTAssertTrue(source.contains("viewModel.lastErrorMessage"))
        XCTAssertTrue(source.contains("Retry"))
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
