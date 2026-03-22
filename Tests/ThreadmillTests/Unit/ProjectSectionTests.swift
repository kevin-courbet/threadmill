import Foundation
import XCTest
@testable import Threadmill

final class ProjectSectionTests: XCTestCase {
    func testProjectSectionSortsThreadsByCreatedAtOnly() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/ProjectSection.swift")

        XCTAssertFalse(source.contains("sourceType == \"main_checkout\""))
        XCTAssertTrue(source.contains("ForEach(displayedThreads)"))
        XCTAssertTrue(source.contains("threads.sorted"))
        XCTAssertTrue(source.contains("createdAt"))
    }

    func testSidebarUsesUnifiedForEachToAvoidImplicitSectionBoundary() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/SidebarView.swift")

        XCTAssertTrue(source.contains("SidebarItem"))
        XCTAssertTrue(source.contains("ForEach(sidebarItems)"))
    }

    func testSidebarDoesNotDisableProjectThreadCreationBehindRepoMapping() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/SidebarView.swift")

        XCTAssertFalse(source.contains("preselectedRepoForNewThread(from: project, repos: appState.repos) != nil"))
        XCTAssertTrue(source.contains("canCreateThread: !appState.remotes.isEmpty"))
    }

    func testProjectHeaderClickTogglesExpansion() throws {
        let source = try loadSource(at: "Sources/Threadmill/Features/Projects/ProjectSection.swift")

        // The header row itself (excluding buttons) should toggle expand/collapse on tap
        XCTAssertTrue(source.contains(".onTapGesture"), "Header must have onTapGesture to toggle expand/collapse")
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
