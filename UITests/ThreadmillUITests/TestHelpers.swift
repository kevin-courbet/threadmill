import AppKit
import Foundation
import XCTest

@MainActor
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
        // Let the app fully process the handshake and sync before interacting
        Thread.sleep(forTimeInterval: 1)
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
        let anyMatchingTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", title, title, title))
            .firstMatch
        let candidates = [
            anyMatchingTitle,
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

    func waitForRequestWhere(method: String, timeout: TimeInterval, predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        try waitFor(timeout: timeout, description: "\(method) matching predicate") {
            server.requestParams(method: method).first(where: predicate)
        }
    }

    func waitForRequestCount(method: String, count: Int, timeout: TimeInterval) throws {
        _ = try waitFor(timeout: timeout, description: "\(method) count >= \(count)") {
            server.requestParams(method: method).count >= count ? true : nil
        }
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
        let database = try DatabaseManager(databasePath: databasePath)
        let remoteID = try database.allRemotes().first(where: { $0.name == "beast" })?.id ?? "remote-ui-test"

        try database.saveRemote(
            Remote(
                id: remoteID,
                name: "beast",
                host: "127.0.0.1",
                daemonPort: Int(daemonPort),
                useSSHTunnel: false,
                cloneRoot: "/home/wsl/dev",
                isDefault: true
            )
        )

        let repos = projects.compactMap(\.repo).map {
            Repo(
                id: $0.id,
                owner: $0.owner,
                name: $0.name,
                fullName: $0.fullName,
                cloneURL: $0.cloneURL,
                defaultBranch: $0.defaultBranch,
                isPrivate: $0.isPrivate,
                cachedAt: Date(timeIntervalSince1970: 1)
            )
        }
        for repo in repos {
            try database.saveRepo(repo)
        }

        try database.replaceAllFromDaemon(
            projects: projects.map {
                Project(
                    id: $0.id,
                    name: $0.name,
                    remotePath: $0.path,
                    defaultBranch: $0.defaultBranch,
                    presets: $0.presets.map { PresetConfig(name: $0.name, command: $0.command, cwd: $0.cwd) },
                    remoteId: remoteID,
                    repoId: $0.repo?.id
                )
            },
            threads: projects.map {
                ThreadModel(
                    id: $0.thread.id,
                    projectId: $0.id,
                    name: $0.thread.name,
                    branch: $0.thread.branch,
                    worktreePath: $0.thread.worktreePath,
                    status: ThreadStatus(rawValue: $0.thread.status) ?? .active,
                    sourceType: $0.thread.sourceType,
                    createdAt: $0.thread.createdAt,
                    tmuxSession: $0.thread.tmuxSession
                )
            },
            remoteId: remoteID
        )
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
