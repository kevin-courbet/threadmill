import Foundation
import XCTest

final class NewThreadSheetSourceTests: XCTestCase {
    func testCreateThreadUsesRepoOverloadInsteadOfProjectIDOverload() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            let sourcePath = repositoryRoot.appendingPathComponent("Sources/Threadmill/Features/Threads/NewThreadSheet.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        guard
            let createThreadStart = source.range(of: "private func createThread() async {")?.lowerBound,
            let selectedRemoteStart = source.range(of: "private var selectedRemote: Remote?")?.lowerBound
        else {
            return XCTFail("Expected createThread implementation in NewThreadSheet")
        }

        let createThreadSource = String(source[createThreadStart..<selectedRemoteStart])

        XCTAssertTrue(createThreadSource.contains("appState.createThread("))
        XCTAssertTrue(createThreadSource.contains("repo: repo"))
        XCTAssertTrue(createThreadSource.contains("remote: remote"))
        XCTAssertFalse(createThreadSource.contains("projectID: projectID"))
    }
}
