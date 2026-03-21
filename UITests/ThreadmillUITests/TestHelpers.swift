import AppKit
import Foundation
import XCTest

struct UITestHarness {
    let app: XCUIApplication
    let server: MockSpindleServer

    private let tempDirectory: URL
    private let appProcess: Process

    static func launch(with fixture: [MockSpindleServer.ProjectFixture]) throws -> UITestHarness {
        let server = MockSpindleServer()
        server.useFixture(fixture)
        try server.start()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-xcuitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let homeDirectory = tempDirectory.appendingPathComponent("home", isDirectory: true)
        let preferencesDirectory = homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        let configDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let databasePath = tempDirectory.appendingPathComponent("threadmill.db").path
        try seedDatabase(at: databasePath, daemonPort: server.port, projects: fixture)

        let appProcess = try launchApp(daemonPort: server.port, databasePath: databasePath, homeDirectory: homeDirectory)
        try waitForLaunchedApplication(processIdentifier: appProcess.processIdentifier)
        let app = XCUIApplication(bundleIdentifier: "dev.threadmill.app")
        NSRunningApplication(processIdentifier: appProcess.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])

        guard app.windows.firstMatch.waitForExistence(timeout: 15) else {
            throw UITestError("Threadmill window did not appear")
        }

        let harness = UITestHarness(app: app, server: server, tempDirectory: tempDirectory, appProcess: appProcess)
        _ = try harness.waitForRequest(method: "session.hello", index: 0, timeout: 15)
        _ = try harness.waitForRequest(method: "project.list", index: 0, timeout: 15)
        return harness
    }

    func tearDown() {
        if appProcess.isRunning {
            appProcess.terminate()
            appProcess.waitUntilExit()
        }
        server.stop()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func click(identifier: String, timeout: TimeInterval = 15) throws {
        let element = try waitForElement(identifier: identifier, timeout: timeout)
        element.click()
    }

    func waitForTitledElement(_ title: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        let candidates = [
            app.buttons[title].firstMatch,
            app.staticTexts[title].firstMatch,
            app.outlines.buttons[title].firstMatch,
            app.outlines.staticTexts[title].firstMatch,
            app.cells.staticTexts[title].firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in candidates where candidate.exists {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw UITestError("Element titled \(title) did not appear")
    }

    func clickTitledElement(_ title: String, timeout: TimeInterval = 15) throws {
        let element = try waitForTitledElement(title, timeout: timeout)
        element.click()
    }

    func clickMode(identifier: String, label: String, timeout: TimeInterval = 15) throws {
        let byIdentifier = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: 2) {
            byIdentifier.click()
            return
        }

        let byLabel = app.segmentedControls.buttons[label].firstMatch
        guard byLabel.waitForExistence(timeout: timeout) else {
            throw UITestError("Mode \(identifier) did not appear")
        }
        byLabel.click()
    }

    func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    func waitForRequest(method: String, index: Int, timeout: TimeInterval) throws -> [String: Any] {
        try waitFor(timeout: timeout, description: "\(method)[\(index)]") {
            let requests = server.requestParams(method: method)
            guard requests.count > index else { return nil }
            return requests[index]
        }
    }

    func waitForElement(identifier: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        let candidates = identifierCandidates(identifier)
        while Date() < deadline {
            for candidate in candidates where candidate.exists {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw UITestError("Element \(identifier) did not appear")
    }

    private func identifierCandidates(_ identifier: String) -> [XCUIElement] {
        [
            app.buttons.matching(identifier: identifier).firstMatch,
            app.staticTexts.matching(identifier: identifier).firstMatch,
            app.groups.matching(identifier: identifier).firstMatch,
            app.outlines.matching(identifier: identifier).firstMatch,
            app.segmentedControls.buttons.matching(identifier: identifier).firstMatch,
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch,
        ]
    }
    private static func launchApp(daemonPort: UInt16, databasePath: String, homeDirectory: URL) throws -> Process {
        let process = Process()
        let appBundle = try locateAppBundle()
        process.executableURL = appBundle.appendingPathComponent("Contents/MacOS/Threadmill")
        process.currentDirectoryURL = repositoryRoot()

        var environment = ProcessInfo.processInfo.environment
        environment["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        environment["THREADMILL_HOST"] = "127.0.0.1"
        environment["THREADMILL_DAEMON_PORT"] = "\(daemonPort)"
        environment["THREADMILL_DB_PATH"] = databasePath
        environment["THREADMILL_USE_MOCK_TERMINAL"] = "1"
        environment["HOME"] = homeDirectory.path
        environment["CFFIXED_USER_HOME"] = homeDirectory.path
        environment["XDG_CONFIG_HOME"] = homeDirectory.appendingPathComponent(".config", isDirectory: true).path
        process.environment = environment

        try process.run()
        return process
    }

    private static func waitForLaunchedApplication(processIdentifier: Int32) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if NSRunningApplication(processIdentifier: processIdentifier) != nil {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw UITestError("Threadmill process did not register with Launch Services")
    }

    private static func locateAppBundle() throws -> URL {
        let root = repositoryRoot()
        let candidates = [
            root.appendingPathComponent(".build/debug/Threadmill.app", isDirectory: true),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/Threadmill.app", isDirectory: true),
            root.appendingPathComponent(".build/x86_64-apple-macosx/debug/Threadmill.app", isDirectory: true),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/Threadmill").path) {
            return candidate
        }

        throw UITestError("Threadmill.app bundle not found. Run `task test:ui` or `bash Scripts/package_app.sh` first.")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func seedDatabase(at databasePath: String, daemonPort: UInt16, projects: [MockSpindleServer.ProjectFixture]) throws {
        let databaseURL = URL(fileURLWithPath: databasePath)
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let remoteID = "remote-ui-test"
        let repos = projects.compactMap(\.repo)
        let projectInserts = projects.map { project -> String in
            let presetsData = try! JSONSerialization.data(withJSONObject: project.presets.map {
                ["name": $0.name, "command": $0.command, "cwd": $0.cwd as Any]
            })
            let presetsJSON = String(decoding: presetsData, as: UTF8.self)
            return "INSERT INTO projects (id, name, remote_path, default_branch, presets_json, remote_id, repo_id) VALUES (\(sql(project.id)), \(sql(project.name)), \(sql(project.path)), \(sql(project.defaultBranch)), \(sql(presetsJSON)), \(sql(remoteID)), \(sql(project.repo?.id)));"
        }

        let repoInserts = repos.map { repo in
            "INSERT INTO repos (id, owner, name, full_name, clone_url, default_branch, is_private, cached_at) VALUES (\(sql(repo.id)), \(sql(repo.owner)), \(sql(repo.name)), \(sql(repo.fullName)), \(sql(repo.cloneURL)), \(sql(repo.defaultBranch)), \(repo.isPrivate ? 1 : 0), \(sql("2026-03-21 00:00:00.000")));"
        }

        let sqlScript = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations (identifier) VALUES
            ('v1'),
            ('v2_project_presets'),
            ('v3_thread_port_offset'),
            ('v4_chat_conversation'),
            ('v5_browser_session'),
            ('v6_remote_model'),
            ('v7_repo_model'),
            ('v8_remote_default_flag');

        CREATE TABLE remotes (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            host TEXT NOT NULL,
            daemon_port INTEGER NOT NULL,
            use_ssh_tunnel INTEGER NOT NULL,
            clone_root TEXT NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE repos (
            id TEXT PRIMARY KEY,
            owner TEXT NOT NULL,
            name TEXT NOT NULL,
            full_name TEXT NOT NULL UNIQUE,
            clone_url TEXT NOT NULL,
            default_branch TEXT NOT NULL,
            is_private INTEGER NOT NULL,
            cached_at TEXT NOT NULL
        );

        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            remote_path TEXT NOT NULL,
            default_branch TEXT NOT NULL,
            presets_json TEXT NOT NULL DEFAULT '[]',
            remote_id TEXT REFERENCES remotes(id) ON DELETE SET NULL,
            repo_id TEXT REFERENCES repos(id) ON DELETE SET NULL
        );

        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            branch TEXT NOT NULL,
            worktree_path TEXT NOT NULL,
            status TEXT NOT NULL,
            source_type TEXT NOT NULL,
            created_at TEXT NOT NULL,
            tmux_session TEXT NOT NULL DEFAULT '',
            port_offset INTEGER
        );

        CREATE TABLE chatConversation (
            id TEXT NOT NULL PRIMARY KEY,
            threadID TEXT NOT NULL,
            opencodeSessionID TEXT,
            title TEXT NOT NULL DEFAULT '',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            isArchived INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_chatConversation_threadID ON chatConversation(threadID);

        CREATE TABLE browserSession (
            id TEXT NOT NULL PRIMARY KEY,
            threadID TEXT NOT NULL,
            url TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            "order" INTEGER NOT NULL,
            createdAt TEXT NOT NULL
        );
        CREATE INDEX idx_browserSession_threadID ON browserSession(threadID);
        CREATE UNIQUE INDEX idx_remotes_default_true ON remotes(is_default) WHERE is_default = 1;

        INSERT INTO remotes (id, name, host, daemon_port, use_ssh_tunnel, clone_root, is_default)
        VALUES (\(sql(remoteID)), 'beast', '127.0.0.1', \(daemonPort), 0, '/home/wsl/dev', 1);

        \(repoInserts.joined(separator: "\n"))
        \(projectInserts.joined(separator: "\n"))
        """

        try runSQLite(databasePath: databasePath, sqlScript: sqlScript)
    }

    private static func runSQLite(databasePath: String, sqlScript: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        input.fileHandleForWriting.write(Data(sqlScript.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
            throw UITestError(message)
        }
    }

    private static func sql(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func waitFor<T>(timeout: TimeInterval, description: String, body: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw UITestError("Timed out waiting for \(description)")
    }
}

struct UITestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
