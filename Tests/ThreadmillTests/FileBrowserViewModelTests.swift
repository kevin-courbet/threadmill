import XCTest
@testable import Threadmill

@MainActor
final class FileBrowserViewModelTests: XCTestCase {
    func testListDirectoryStoresEntriesFromRemoteResponse() async {
        let service = MockFileBrowserService()
        let rootPath = "/tmp/threadmill-worktree"

        service.listResponses[rootPath] = [
            FileBrowserEntry(name: "Sources", path: "\(rootPath)/Sources", isDirectory: true, size: 0),
            FileBrowserEntry(name: "README.md", path: "\(rootPath)/README.md", isDirectory: false, size: 12),
        ]

        let viewModel = FileBrowserViewModel(rootPath: rootPath, fileService: service)
        await viewModel.listDirectory(path: rootPath)

        XCTAssertEqual(service.listedPaths, [rootPath])
        XCTAssertEqual(viewModel.currentPath, rootPath)
        XCTAssertEqual(viewModel.entries(for: rootPath).map(\.name), ["Sources", "README.md"])
    }
}

@MainActor
private final class MockFileBrowserService: FileBrowsing {
    var listResponses: [String: [FileBrowserEntry]] = [:]
    var listedPaths: [String] = []

    func listDirectory(path: String) async throws -> [FileBrowserEntry] {
        listedPaths.append(path)
        return listResponses[path] ?? []
    }

    func readFile(path _: String) async throws -> FileReadPayload {
        FileReadPayload(content: "", size: 0)
    }
}
