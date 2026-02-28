import Foundation
import Combine

struct OpenFileInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let content: String
}

enum FileServiceError: LocalizedError {
    case invalidResponse(method: String)
    case decodeFailed(method: String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(method):
            return "Invalid response for \(method)."
        case let .decodeFailed(method):
            return "Failed to decode \(method) response."
        }
    }
}

@MainActor
final class FileService: FileBrowsing {
    private struct ListResponse: Decodable {
        let entries: [FileBrowserEntry]
    }

    private struct GitStatusResponse: Decodable {
        let entries: [String: FileGitStatus]
    }

    private let connectionManager: any ConnectionManaging

    init(connectionManager: any ConnectionManaging) {
        self.connectionManager = connectionManager
    }

    func listDirectory(path: String) async throws -> [FileBrowserEntry] {
        let result = try await connectionManager.request(
            method: "file.list",
            params: ["path": path],
            timeout: 20
        )
        return try decode(result, method: "file.list", as: ListResponse.self).entries
    }

    func readFile(path: String) async throws -> FileReadPayload {
        let result = try await connectionManager.request(
            method: "file.read",
            params: ["path": path],
            timeout: 20
        )
        return try decode(result, method: "file.read", as: FileReadPayload.self)
    }

    func gitStatus(path: String) async throws -> [String: FileGitStatus] {
        let result = try await connectionManager.request(
            method: "file.git_status",
            params: ["path": path],
            timeout: 20
        )
        return try decode(result, method: "file.git_status", as: GitStatusResponse.self).entries
    }

    private func decode<T: Decodable>(_ value: Any, method: String, as type: T.Type) throws -> T {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw FileServiceError.invalidResponse(method: method)
        }

        let data = try JSONSerialization.data(withJSONObject: value)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FileServiceError.decodeFailed(method: method)
        }
    }
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
    let rootPath: String
    let currentPath: String
    @Published var openFiles: [OpenFileInfo] = []
    @Published var selectedFileId: UUID?
    @Published var expandedPaths: Set<String> = []
    @Published var gitFileStatus: [String: FileGitStatus] = [:]
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var isOpeningFile = false

    private let fileService: any FileBrowsing
    private var directoryEntriesByPath: [String: [FileBrowserEntry]] = [:]
    private var lastDirectoryErrorPath: String?
    private var lastFileReadErrorPath: String?
    private var initialGitStatusTask: Task<Void, Never>?

    init(rootPath: String, fileService: any FileBrowsing) {
        self.rootPath = rootPath
        self.currentPath = rootPath
        self.fileService = fileService

        initialGitStatusTask = Task { [weak self] in
            await self?.loadGitStatus()
            await MainActor.run {
                self?.initialGitStatusTask = nil
            }
        }
    }

    var selectedOpenFile: OpenFileInfo? {
        guard let selectedFileId else {
            return nil
        }
        return openFiles.first(where: { $0.id == selectedFileId })
    }

    var canSelectPreviousFile: Bool {
        guard
            let selectedFileId,
            let index = openFiles.firstIndex(where: { $0.id == selectedFileId })
        else {
            return false
        }

        return index > 0
    }

    var canSelectNextFile: Bool {
        guard
            let selectedFileId,
            let index = openFiles.firstIndex(where: { $0.id == selectedFileId })
        else {
            return false
        }

        return index + 1 < openFiles.count
    }

    func loadInitialDirectoryIfNeeded() async {
        guard directoryEntriesByPath[rootPath] == nil else {
            return
        }
        await listDirectory(path: rootPath)
    }

    func listDirectory(path: String) async {
        if let initialGitStatusTask {
            await initialGitStatusTask.value
        }

        loadingDirectories.insert(path)
        defer { loadingDirectories.remove(path) }

        do {
            let entries = try await fileService.listDirectory(path: path)
            directoryEntriesByPath[path] = entries
            lastErrorMessage = nil
            lastDirectoryErrorPath = nil
            await loadGitStatus()
        } catch {
            directoryEntriesByPath[path] = []
            lastErrorMessage = error.localizedDescription
            lastDirectoryErrorPath = path
        }
    }

    func loadGitStatus() async {
        do {
            gitFileStatus = try await fileService.gitStatus(path: rootPath)
        } catch {
            gitFileStatus = [:]
        }
    }

    func gitStatus(for absolutePath: String) -> FileGitStatus? {
        let rootURL = URL(fileURLWithPath: rootPath)
        let fileURL = URL(fileURLWithPath: absolutePath)
        guard let relativePath = relativePath(from: rootURL, to: fileURL) else {
            return nil
        }

        return gitFileStatus[relativePath]
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path

        guard file == root || file.hasPrefix(root + "/") else {
            return nil
        }

        let relative = String(file.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : relative
    }

    func entries(for path: String) -> [FileBrowserEntry] {
        directoryEntriesByPath[path] ?? []
    }

    func isDirectoryLoading(_ path: String) -> Bool {
        loadingDirectories.contains(path)
    }

    func toggleDirectory(_ entry: FileBrowserEntry) async {
        guard entry.isDirectory else {
            return
        }

        if expandedPaths.contains(entry.path) {
            expandedPaths.remove(entry.path)
            return
        }

        expandedPaths.insert(entry.path)
        if directoryEntriesByPath[entry.path] == nil {
            await listDirectory(path: entry.path)
            return
        }

        await loadGitStatus()
    }

    func openFile(path: String) async {
        if let existing = openFiles.first(where: { $0.path == path }) {
            selectedFileId = existing.id
            return
        }

        isOpeningFile = true
        defer { isOpeningFile = false }

        do {
            let payload = try await fileService.readFile(path: path)
            let openFile = OpenFileInfo(
                id: UUID(),
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                content: payload.content
            )
            openFiles.append(openFile)
            selectedFileId = openFile.id
            lastErrorMessage = nil
            lastFileReadErrorPath = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            lastFileReadErrorPath = path
        }
    }

    func retryLastListDirectory() async {
        guard let path = lastDirectoryErrorPath else {
            return
        }
        await listDirectory(path: path)
    }

    func retryLastOpenFile() async {
        guard let path = lastFileReadErrorPath else {
            return
        }
        await openFile(path: path)
    }

    func selectFile(id: UUID) {
        selectedFileId = id
    }

    func closeFile(id: UUID) {
        guard let index = openFiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        openFiles.remove(at: index)
        if selectedFileId == id {
            selectedFileId = openFiles.indices.contains(index)
                ? openFiles[index].id
                : openFiles.last?.id
        }
    }

    func selectPreviousFile() {
        guard
            let selectedFileId,
            let index = openFiles.firstIndex(where: { $0.id == selectedFileId }),
            index > 0
        else {
            return
        }

        self.selectedFileId = openFiles[index - 1].id
    }

    func selectNextFile() {
        guard
            let selectedFileId,
            let index = openFiles.firstIndex(where: { $0.id == selectedFileId }),
            index + 1 < openFiles.count
        else {
            return
        }

        self.selectedFileId = openFiles[index + 1].id
    }
}
