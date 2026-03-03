import Foundation
import XCTest
@testable import Threadmill

final class ProjectSectionTests: XCTestCase {
    func testInstantToggleTransactionDisablesAnimations() {
        let transaction = instantToggleTransaction()

        XCTAssertTrue(transaction.disablesAnimations)
        XCTAssertNil(transaction.animation)
    }

    func testProjectSectionTreatsMainCheckoutAsPrimaryRow() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/ProjectSection.swift")

        XCTAssertTrue(source.contains("sourceType == \"main_checkout\""))
        XCTAssertTrue(source.contains("ForEach(displayedThreads)"))
        XCTAssertTrue(source.contains("threads.sorted"))
        XCTAssertFalse(source.contains("mainBranchThreadRow"))
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
