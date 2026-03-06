import Foundation
import XCTest
@testable import Threadmill

final class ProjectSectionTests: XCTestCase {
    func testProjectSectionUsesNativeSectionDisclosureAndNoInstantTransaction() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/ProjectSection.swift")

        XCTAssertTrue(source.contains("Section(isExpanded: $isExpanded)"))
        XCTAssertTrue(source.contains("chevron.right"))
        XCTAssertFalse(source.contains("instantToggleTransaction"))
    }

    func testProjectSectionSortsThreadsByCreatedAtOnly() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/ProjectSection.swift")

        XCTAssertFalse(source.contains("sourceType == \"main_checkout\""))
        XCTAssertTrue(source.contains("ForEach(displayedThreads)"))
        XCTAssertTrue(source.contains("threads.sorted"))
        XCTAssertTrue(source.contains("createdAt"))
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
