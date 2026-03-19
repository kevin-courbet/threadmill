import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import Threadmill

@MainActor
final class ThreadmillUITests: XCTestCase {
    func testChatSessionTabCloseRemovesTabAndKeepsOtherSelected() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path

        // MockSpindleServer provides thread-main (project-main) by default.
        // Seed DB with 2 chat conversations linked to that thread.
        let conversationA = "conv-a-\(UUID().uuidString)"
        let conversationB = "conv-b-\(UUID().uuidString)"
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [])
        try seedChatConversations(
            dbPath: dbPath,
            threadID: "thread-main",
            conversations: [
                (id: conversationA, title: "Session A", opencodeSessionID: "fake-oc-a"),
                (id: conversationB, title: "Session B", opencodeSessionID: "fake-oc-b"),
            ]
        )
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])
        let ax = AXTestClient(pid: appProcess.processIdentifier)

        // Wait for connection and thread auto-selection
        _ = try waitForDebugArtifact(
            named: "app",
            timeout: 20,
            description: "app debug artifact did not reach connected state"
        ) { artifact in
            artifact.localizedCaseInsensitiveContains("\"status\" : \"connected\"") ? artifact : nil
        }

        // Thread-main is auto-selected by ensureValidSelection(). Default mode is
        // chat, so the chat view should already be visible. Wait for automation buttons
        // that prove conversations loaded from the seeded DB.
        _ = try ax.waitForIdentifier("automation.select-chat.\(conversationA)", timeout: 20)
        _ = try ax.waitForIdentifier("automation.select-chat.\(conversationB)", timeout: 5)

        // Select conversation B
        try ax.click(identifier: "automation.select-chat.\(conversationB)", timeout: 5)

        // Close conversation A via automation button (triggers archiveChatConversations)
        try ax.click(identifier: "automation.close-chat.\(conversationA)", timeout: 5)

        // Verify: conversation A disappears AND stays gone after settling.
        // The bug: archive briefly removes it, but ChatViewModel.loadConversations
        // (triggered by reloadToken change) re-fetches including archived conversations,
        // then publishConversationState pushes them back into chatConversations.
        try ax.waitUntilMissing(identifier: "automation.select-chat.\(conversationA)", timeout: 10)

        // Wait for any async reload cycles to complete, then assert still gone.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        XCTAssertFalse(
            ax.hasElement(identifier: "automation.select-chat.\(conversationA)"),
            "Conversation A reappeared after close — archived conversation leaked back through reload"
        )

        // Verify: conversation B still exists
        _ = try ax.waitForIdentifier("automation.select-chat.\(conversationB)", timeout: 5)
    }

    func testMacOSUIE2EFlowWithReconnect() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [])
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])

        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try ax.waitForValueContains(identifier: "connection.status", value: "connected", timeout: 20)
        _ = try ax.waitForTitle("Automation Open Add Project", timeout: 10)

        try ax.clickTitle("Automation Open Add Project")
        _ = try ax.waitForTitle("Automation Open New Thread", timeout: 10)

        try ax.clickTitle("Automation Open New Thread")
        _ = try ax.waitForTitle("Automation Switch thread-ui-e2e-thread", timeout: 15)

        try ax.clickTitle("Automation Switch thread-ui-e2e-thread")
        _ = try ax.waitForTitle("Automation Preset terminal", timeout: 10)
        _ = try ax.waitForTitle("Automation Preset dev-server", timeout: 10)

        try ax.clickTitle("Automation Preset dev-server")
        try ax.waitForValueContains(identifier: "terminal.content", value: "dev-server", timeout: 10)
        try ax.clickTitle("Automation Preset terminal")
        try ax.waitForValueContains(identifier: "terminal.content", value: "terminal", timeout: 10)

        try ax.clickTitle("Automation Close Selected")
        try ax.waitUntilTitleMissing("Automation Switch thread-ui-e2e-thread", timeout: 10)

        mockServer.stop()
        try ax.waitForAnyValueContains(
            identifier: "connection.status",
            values: ["reconnecting", "disconnected", "connecting"],
            timeout: 20
        )

        try mockServer.start()
        try ax.waitForValueContains(identifier: "connection.status", value: "connected", timeout: 25)
    }

    func testRepoBasedThreadCreation() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let repo = Repo(
            id: "repo-ui-flow",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [repo])
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])
        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try ax.waitForValueContains(identifier: "connection.status", value: "connected", timeout: 20)

        let threadName = "repo-ui-flow-thread"
        let expectedThreadID = "thread-\(slug(threadName))"

        try createThreadFromRepoUI(repoID: repo.id, threadName: threadName, ax: ax)
        _ = try waitForRequest(method: "project.lookup", on: mockServer, timeout: 12)

        let lookupParams = try XCTUnwrap(mockServer.lastRequestParams(method: "project.lookup"))
        XCTAssertEqual(lookupParams["path"] as? String, "/home/wsl/dev/threadmill")

        _ = try ax.waitForIdentifier("thread.row.\(expectedThreadID)", timeout: 20)
        try ax.click(identifier: "automation.switch-thread.\(expectedThreadID)", timeout: 20)
        _ = try ax.waitForTitle("Automation Preset terminal", timeout: 15)
        _ = try ax.waitForTitle("Automation Preset dev-server", timeout: 15)

        try ax.click(identifier: "automation.select-preset.dev-server", timeout: 10)
        try ax.waitForValueContains(identifier: "terminal.content", value: "dev-server", timeout: 10)
        try ax.click(identifier: "automation.select-preset.terminal", timeout: 10)
        try ax.waitForValueContains(identifier: "terminal.content", value: "terminal", timeout: 10)
    }

    func testProvisioningClonesRepoWhenMissingOnRemote() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let repo = Repo(
            id: "repo-provision-clone",
            owner: "anomalyco",
            name: "threadmill",
            fullName: "anomalyco/threadmill",
            cloneURL: "git@github.com:anomalyco/threadmill.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [repo])
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])
        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try ax.waitForValueContains(identifier: "connection.status", value: "connected", timeout: 20)
        let threadName = "provision-clone-thread"
        let expectedThreadID = "thread-\(slug(threadName))"
        try createThreadFromRepoUI(repoID: repo.id, threadName: threadName, ax: ax)

        _ = try waitForRequest(method: "project.lookup", on: mockServer, timeout: 12)
        let cloneParams = try waitForRequest(method: "project.clone", on: mockServer, timeout: 12)
        XCTAssertEqual(cloneParams["url"] as? String, repo.cloneURL)
        XCTAssertEqual(cloneParams["path"] as? String, "/home/wsl/dev/threadmill")
        _ = try ax.waitForIdentifier("thread.row.\(expectedThreadID)", timeout: 20)
    }

    func testProvisioningSkipsCloneWhenRepoAlreadyOnRemote() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let repo = Repo(
            id: "repo-provision-existing",
            owner: "anomalyco",
            name: "myautonomy",
            fullName: "anomalyco/myautonomy",
            cloneURL: "git@github.com:anomalyco/myautonomy.git",
            defaultBranch: "main",
            isPrivate: true,
            cachedAt: Date(timeIntervalSince1970: 1)
        )

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [repo])
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])
        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try ax.waitForValueContains(identifier: "connection.status", value: "connected", timeout: 20)
        let threadName = "provision-existing-thread"
        let expectedThreadID = "thread-\(slug(threadName))"
        try createThreadFromRepoUI(repoID: repo.id, threadName: threadName, ax: ax)

        let lookupParams = try waitForRequest(method: "project.lookup", on: mockServer, timeout: 12)
        XCTAssertEqual(lookupParams["path"] as? String, "/home/wsl/dev/myautonomy")

        _ = try waitForCondition(timeout: 2, description: "project.clone should not be called") {
            mockServer.requestCount(method: "project.clone") == 0 ? true : nil
        }
        _ = try ax.waitForIdentifier("thread.row.\(expectedThreadID)", timeout: 20)
        XCTAssertGreaterThanOrEqual(mockServer.requestCount(method: "thread.create"), 1)
    }

    func testCmdTStartsTerminalForSelectedThread() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        mockServer.useTerminalFixture()
        try mockServer.start()
        defer { mockServer.stop() }

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port, repos: [])
        defer { try? FileManager.default.removeItem(at: dbRoot) }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbPath)
        try appProcess.run()
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [])
        let ax = AXTestClient(pid: appProcess.processIdentifier)
        _ = try waitForDebugArtifact(
            named: "app",
            timeout: 20,
            description: "app debug artifact did not reach connected state"
        ) { artifact in
            artifact.localizedCaseInsensitiveContains("\"status\" : \"connected\"") ? artifact : nil
        }
        _ = try waitForDebugArtifact(
            named: "thread-detail",
            timeout: 20,
            description: "thread detail artifact did not select the terminal fixture thread"
        ) { artifact in
            artifact.localizedCaseInsensitiveContains("\"selectedThreadID\" : \"thread-terminal\"") ? artifact : nil
        }

        ax.sendKey("t", modifiers: ["cmd"])

        let presetStart = try waitForRequest(method: "preset.start", on: mockServer, timeout: 12)
        XCTAssertEqual(presetStart["preset"] as? String, "terminal")

        _ = try waitForDebugArtifact(
            named: "thread-detail-ui",
            timeout: 12,
            description: "terminal shortcut did not update thread detail state"
        ) { artifact in
            artifact.localizedCaseInsensitiveContains("\"selectedTerminalSessionID\" : \"terminal\"") ? artifact : nil
        }
    }

    private func launchEnvironment(port: UInt16, dbPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        environment["THREADMILL_HOST"] = "127.0.0.1"
        environment["THREADMILL_DAEMON_PORT"] = "\(port)"
        environment["THREADMILL_DB_PATH"] = dbPath
        environment["THREADMILL_USE_MOCK_TERMINAL"] = "1"
        return environment
    }

    private func requireUIE2EEnabledAndTrusted() throws {
        guard ProcessInfo.processInfo.environment["THREADMILL_RUN_UI_E2E"] == "1" else {
            throw XCTSkip("Set THREADMILL_RUN_UI_E2E=1 to run macOS UI E2E test")
        }

        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required for UI E2E tests")
        }
    }

    private func seedDatabase(dbPath: String, port: UInt16, repos: [Repo]) throws {
        let database = try DatabaseManager(databasePath: dbPath)
        let beastID = try database.allRemotes().first(where: { $0.name == "beast" })?.id ?? "remote-beast"

        try database.saveRemote(
            Remote(
                id: beastID,
                name: "beast",
                host: "127.0.0.1",
                daemonPort: Int(port),
                useSSHTunnel: false,
                cloneRoot: "/home/wsl/dev"
            )
        )

        for repo in repos {
            try database.saveRepo(repo)
        }
    }

    private func seedChatConversations(
        dbPath: String,
        threadID: String,
        conversations: [(id: String, title: String, opencodeSessionID: String)]
    ) throws {
        let database = try DatabaseManager(databasePath: dbPath)
        for conv in conversations {
            let conversation = ChatConversation(
                id: conv.id,
                threadID: threadID,
                opencodeSessionID: conv.opencodeSessionID,
                title: conv.title,
                createdAt: Date(),
                isArchived: false
            )
            try database.saveConversation(conversation)
        }
    }

    private func createThreadFromRepoUI(repoID: String, threadName: String, ax: AXTestClient) throws {
        try ax.click(identifier: "repo.section.new-thread.\(repoID)", timeout: 20)
        _ = try ax.waitForIdentifier("sheet.new-thread", timeout: 15)
        try ax.setText(threadName, identifier: "sheet.new-thread.name-input", timeout: 10)
        try ax.click(identifier: "sheet.new-thread.submit-button", timeout: 10)
        try ax.waitUntilMissing(identifier: "sheet.new-thread", timeout: 20)
    }

    private func waitForRequest(method: String, on server: MockSpindleServer, timeout: TimeInterval) throws -> [String: Any] {
        try waitForCondition(timeout: timeout, description: "RPC \(method) was not called") {
            guard server.requestCount(method: method) > 0 else {
                return nil
            }
            return server.lastRequestParams(method: method) ?? [:]
        }
    }

    private func waitForDebugArtifact(named name: String, timeout: TimeInterval, description: String, predicate: (String) -> String?) throws -> String {
        let url = URL(fileURLWithPath: "/tmp/threadmill-debug/\(name).json")
        return try waitForCondition(timeout: timeout, description: description) {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return predicate(text)
        }
    }

    private func waitForCondition<T>(timeout: TimeInterval, description: String, body: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(description)
        throw NSError(domain: "ThreadmillUITests", code: 3, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func slug(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return "item"
        }

        return trimmed
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "--", with: "-")
    }

    private func locateThreadmillExecutable() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["THREADMILL_UI_APP_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/Threadmill"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/Threadmill"),
            root.appendingPathComponent(".build/x86_64-apple-macosx/debug/Threadmill"),
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let message = "Threadmill executable not found. Set THREADMILL_UI_APP_PATH or run swift build --product Threadmill"
        throw NSError(domain: "ThreadmillUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
