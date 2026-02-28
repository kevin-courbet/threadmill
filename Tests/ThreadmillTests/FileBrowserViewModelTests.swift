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

    func testExpandingChildDirectoryKeepsTreeRootAndUsesCachedChildren() async {
        let service = MockFileBrowserService()
        let rootPath = "/tmp/threadmill-worktree"
        let sourcesPath = "\(rootPath)/Sources"

        service.listResponses[rootPath] = [
            FileBrowserEntry(name: "Sources", path: sourcesPath, isDirectory: true, size: 0),
        ]
        service.listResponses[sourcesPath] = [
            FileBrowserEntry(name: "main.swift", path: "\(sourcesPath)/main.swift", isDirectory: false, size: 42),
        ]

        let viewModel = FileBrowserViewModel(rootPath: rootPath, fileService: service)
        await viewModel.listDirectory(path: rootPath)

        guard let sourcesEntry = viewModel.entries(for: rootPath).first else {
            XCTFail("Expected Sources entry at root")
            return
        }

        await viewModel.toggleDirectory(sourcesEntry)

        XCTAssertEqual(viewModel.currentPath, rootPath)
        XCTAssertEqual(service.listedPaths, [rootPath, sourcesPath])
        XCTAssertEqual(viewModel.entries(for: sourcesPath).map(\.name), ["main.swift"])

        await viewModel.toggleDirectory(sourcesEntry)
        await viewModel.toggleDirectory(sourcesEntry)

        XCTAssertEqual(service.listedPaths, [rootPath, sourcesPath])
    }

    func testListDirectoryFailureClearsEntriesAndSetsErrorState() async {
        let service = MockFileBrowserService()
        let rootPath = "/tmp/threadmill-worktree"

        service.listResponses[rootPath] = [
            FileBrowserEntry(name: "README.md", path: "\(rootPath)/README.md", isDirectory: false, size: 12),
        ]

        let viewModel = FileBrowserViewModel(rootPath: rootPath, fileService: service)
        await viewModel.listDirectory(path: rootPath)
        XCTAssertEqual(viewModel.entries(for: rootPath).map(\.name), ["README.md"])

        service.listErrors[rootPath] = MockFileBrowserServiceError.listFailed
        await viewModel.listDirectory(path: rootPath)

        XCTAssertEqual(viewModel.lastErrorMessage, MockFileBrowserServiceError.listFailed.localizedDescription)
        XCTAssertTrue(viewModel.entries(for: rootPath).isEmpty)
    }

    func testInitLoadsGitStatusForRootPath() async {
        let service = MockFileBrowserService()
        let rootPath = "/tmp/threadmill-worktree"
        service.gitStatusResponses[rootPath] = [
            "README.md": .modified,
            "Sources/main.swift": .added,
        ]

        let viewModel = FileBrowserViewModel(rootPath: rootPath, fileService: service)
        await Task.yield()

        XCTAssertEqual(service.gitStatusPaths, [rootPath])
        XCTAssertEqual(viewModel.gitFileStatus["README.md"], .modified)
        XCTAssertEqual(viewModel.gitFileStatus["Sources/main.swift"], .added)
    }

    func testListDirectoryRefreshesGitStatus() async {
        let service = MockFileBrowserService()
        let rootPath = "/tmp/threadmill-worktree"
        service.listResponses[rootPath] = []
        service.gitStatusResponses[rootPath] = ["README.md": .modified]

        let viewModel = FileBrowserViewModel(rootPath: rootPath, fileService: service)
        await viewModel.listDirectory(path: rootPath)

        XCTAssertEqual(service.gitStatusPaths.last, rootPath)
        XCTAssertEqual(viewModel.gitFileStatus["README.md"], .modified)
    }
}

@MainActor
private final class MockFileBrowserService: FileBrowsing {
    var listResponses: [String: [FileBrowserEntry]] = [:]
    var listErrors: [String: Error] = [:]
    var listedPaths: [String] = []
    var gitStatusResponses: [String: [String: FileGitStatus]] = [:]
    var gitStatusErrors: [String: Error] = [:]
    var gitStatusPaths: [String] = []

    func listDirectory(path: String) async throws -> [FileBrowserEntry] {
        listedPaths.append(path)
        if let error = listErrors[path] {
            throw error
        }
        return listResponses[path] ?? []
    }

    func readFile(path _: String) async throws -> FileReadPayload {
        FileReadPayload(content: "", size: 0)
    }

    func gitStatus(path: String) async throws -> [String: FileGitStatus] {
        gitStatusPaths.append(path)
        if let error = gitStatusErrors[path] {
            throw error
        }
        return gitStatusResponses[path] ?? [:]
    }
}

private enum MockFileBrowserServiceError: LocalizedError {
    case listFailed

    var errorDescription: String? {
        switch self {
        case .listFailed:
            return "Could not list directory"
        }
    }
}
