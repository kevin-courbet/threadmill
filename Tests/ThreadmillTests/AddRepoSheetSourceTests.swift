import Foundation
import XCTest

final class AddRepoSheetSourceTests: XCTestCase {
    func testAddRepoSheetUsesSharedGitHubAuthManagerFromEnvironment() throws {
        let addRepoSheetSource = try loadSource(at: "Sources/Threadmill/Features/Repos/AddRepoSheet.swift")
        XCTAssertTrue(addRepoSheetSource.contains("let authManager: GitHubAuthManager"))
        XCTAssertFalse(addRepoSheetSource.contains("@State private var authManager = GitHubAuthManager()"))

        let contentViewSource = try loadSource(at: "Sources/Threadmill/Views/ContentView.swift")
        XCTAssertTrue(contentViewSource.contains("@Environment(GitHubAuthManager.self)"))
        XCTAssertTrue(contentViewSource.contains("AddRepoSheet(authManager: gitHubAuthManager)"))
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
