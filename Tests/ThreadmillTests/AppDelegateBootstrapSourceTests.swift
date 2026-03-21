import Foundation
import XCTest

final class AppDelegateBootstrapSourceTests: XCTestCase {
    func testBootstrapDoesNotFatalErrorWhenNoRemotesOrConfigSyncFails() throws {
        let source = try loadSource(at: "Sources/Threadmill/App/AppDelegate.swift")

        XCTAssertFalse(source.contains("fatalError(\"Failed to bootstrap Threadmill: no remotes available\")"))
        XCTAssertTrue(source.contains("do {"))
        XCTAssertTrue(source.contains("try databaseManager.syncRemotesFromConfigFile()"))
        XCTAssertTrue(source.contains("catch {"))
        XCTAssertFalse(source.contains("as? ConnectionManager"))
        XCTAssertTrue(source.contains("onConnectionCreated:"))
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
