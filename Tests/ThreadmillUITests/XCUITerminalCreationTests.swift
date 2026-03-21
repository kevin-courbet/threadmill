import AppKit
import ApplicationServices
import XCTest
@testable import Threadmill

/// E2E test for terminal session creation via real UI interaction.
///
/// Uses MockSpindleServer as the daemon, launches the app as a bundled process,
/// and drives the UI through keyboard shortcuts and AXTestClient.
///
/// Test case: create 2 terminal sessions
/// - Cmd+2 switches to Terminal mode, auto-starting the first preset (terminal)
/// - Cmd+T creates the second terminal session (re-uses terminal or picks next preset)
///
/// Validates the full lifecycle through mock daemon RPC observation.
@MainActor
final class XCUITerminalCreationTests: XCTestCase {

    func testCreateTwoTerminalSessionsEndToEnd() throws {
        try requireUIE2EEnabledAndTrusted()

        // --- Setup mock daemon with 2-preset terminal fixture ---
        let mockServer = MockSpindleServer()
        mockServer.useTerminalFixture(
            projectID: "project-e2e",
            threadID: "thread-e2e"
        )
        try mockServer.start()
        defer { mockServer.stop() }

        // --- Seed database ---
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-xcui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port)
        defer { try? FileManager.default.removeItem(at: dbRoot) }

        // --- Launch app ---
        let appProcess = try launchApp(port: mockServer.port, dbPath: dbPath)
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        let ax = AXTestClient(pid: appProcess.processIdentifier)

        // --- Wait for app to connect and sync ---
        try waitFor(timeout: 20, description: "App should complete session.hello handshake") {
            mockServer.requestCount(method: "session.hello") > 0
        }
        try waitFor(timeout: 10, description: "App should sync project.list") {
            mockServer.requestCount(method: "project.list") > 0
        }
        Thread.sleep(forTimeInterval: 1)

        // === STEP 1: Switch to Terminal mode (Cmd+2) ===
        // This triggers attachSelectedTerminalIfNeeded which starts the default preset
        ax.sendKey("2", modifiers: ["cmd"])

        // Verify first preset.start for "terminal"
        let firstStart = try waitForRPC(method: "preset.start", on: mockServer, timeout: 10,
                                        description: "Cmd+2 should trigger preset.start for terminal")
        XCTAssertEqual(firstStart["preset"] as? String, "terminal",
                       "First session should start the 'terminal' preset")

        // Verify first terminal.attach
        let firstAttach = try waitForRPC(method: "terminal.attach", on: mockServer, timeout: 10,
                                         description: "First terminal.attach after preset.start")
        XCTAssertEqual(firstAttach["preset"] as? String, "terminal",
                       "First attach should be for 'terminal' preset")

        let startCountAfterFirst = mockServer.requestCount(method: "preset.start")
        let attachCountAfterFirst = mockServer.requestCount(method: "terminal.attach")

        // === STEP 2: Create second terminal session (Cmd+T) ===
        // Cmd+T calls startPreset(named: "terminal").
        // Since terminal is already running, it will get "preset already running"
        // and proceed to attach (not start a new preset).
        ax.sendKey("t", modifiers: ["cmd"])
        Thread.sleep(forTimeInterval: 2)

        // Cmd+T should trigger at least one more terminal.attach
        // (it may or may not trigger another preset.start depending on whether
        // the preset is already running)
        let gotSecondAttach = waitForCondition(timeout: 10) {
            mockServer.requestCount(method: "terminal.attach") > attachCountAfterFirst
        }
        XCTAssertTrue(gotSecondAttach,
                      "Cmd+T should trigger another terminal.attach (reattach to running preset)")

        // === STEP 3: Verify final RPC state ===
        let totalAttaches = mockServer.requestCount(method: "terminal.attach")
        XCTAssertGreaterThanOrEqual(totalAttaches, 2,
                                    "Should have at least 2 terminal.attach calls total")

        // The terminal preset should appear in all attach calls
        let allAttachParams = mockServer.requestParams(method: "terminal.attach")
        let attachedPresets = allAttachParams.compactMap { $0["preset"] as? String }
        XCTAssertTrue(attachedPresets.allSatisfy { $0 == "terminal" },
                      "All attaches from Cmd+2 and Cmd+T should be for 'terminal' preset")
    }

    func testTerminalModeAutoStartsOnThreadSelection() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        mockServer.useTerminalFixture(
            projectID: "project-autostart",
            threadID: "thread-autostart"
        )
        try mockServer.start()
        defer { mockServer.stop() }

        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-xcui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port)
        defer { try? FileManager.default.removeItem(at: dbRoot) }

        let appProcess = try launchApp(port: mockServer.port, dbPath: dbPath)
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try waitFor(timeout: 20, description: "App should complete handshake") {
            mockServer.requestCount(method: "session.hello") > 0
        }
        try waitFor(timeout: 10, description: "App should sync project.list") {
            mockServer.requestCount(method: "project.list") > 0
        }
        Thread.sleep(forTimeInterval: 1)

        // Switch to terminal mode
        ax.sendKey("2", modifiers: ["cmd"])

        // Verify the full terminal lifecycle: preset.start → terminal.attach
        try waitForRPC(method: "preset.start", on: mockServer, timeout: 10,
                       description: "Terminal mode should auto-start a preset")
        try waitForRPC(method: "terminal.attach", on: mockServer, timeout: 10,
                       description: "Terminal mode should auto-attach after start")
    }

    func testCmdTReattachesAlreadyRunningTerminal() throws {
        try requireUIE2EEnabledAndTrusted()

        let mockServer = MockSpindleServer()
        mockServer.useTerminalFixture(
            projectID: "project-reattach",
            threadID: "thread-reattach"
        )
        try mockServer.start()
        defer { mockServer.stop() }

        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-xcui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        let dbPath = dbRoot.appendingPathComponent("threadmill.db").path
        try seedDatabase(dbPath: dbPath, port: mockServer.port)
        defer { try? FileManager.default.removeItem(at: dbRoot) }

        let appProcess = try launchApp(port: mockServer.port, dbPath: dbPath)
        defer {
            if appProcess.isRunning {
                appProcess.terminate()
                appProcess.waitUntilExit()
            }
        }

        let ax = AXTestClient(pid: appProcess.processIdentifier)

        try waitFor(timeout: 20, description: "App should complete handshake") {
            mockServer.requestCount(method: "session.hello") > 0
        }
        try waitFor(timeout: 10, description: "App should sync project.list") {
            mockServer.requestCount(method: "project.list") > 0
        }
        Thread.sleep(forTimeInterval: 1)

        // First: switch to terminal mode to start terminal
        ax.sendKey("2", modifiers: ["cmd"])
        try waitForRPC(method: "terminal.attach", on: mockServer, timeout: 10,
                       description: "First terminal.attach")

        let attachCountBefore = mockServer.requestCount(method: "terminal.attach")

        // Second: Cmd+T should reattach (terminal preset is already running)
        ax.sendKey("t", modifiers: ["cmd"])

        try waitFor(timeout: 10, description: "Cmd+T should trigger another terminal.attach") {
            mockServer.requestCount(method: "terminal.attach") > attachCountBefore
        }
    }

    // MARK: - Infrastructure

    private func requireUIE2EEnabledAndTrusted() throws {
        guard ProcessInfo.processInfo.environment["THREADMILL_RUN_UI_E2E"] == "1" else {
            throw XCTSkip("Set THREADMILL_RUN_UI_E2E=1 to run macOS UI E2E tests")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required for UI E2E tests")
        }
    }

    private func launchApp(port: UInt16, dbPath: String) throws -> Process {
        let appPath = try locateAppBundle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(appPath)/Contents/MacOS/Threadmill")
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.environment = launchEnvironment(port: port, dbPath: dbPath)
        try process.run()

        Thread.sleep(forTimeInterval: 2)
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
        Thread.sleep(forTimeInterval: 0.5)

        return process
    }

    private func seedDatabase(dbPath: String, port: UInt16) throws {
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

    private func locateAppBundle() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/Threadmill.app").path,
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/Threadmill.app").path,
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: "\(candidate)/Contents/MacOS/Threadmill") {
                return candidate
            }
        }
        throw XCTSkip("Threadmill.app bundle not found. Run `swift build --product Threadmill` first.")
    }

    @discardableResult
    private func waitForRPC(
        method: String,
        on server: MockSpindleServer,
        timeout: TimeInterval,
        description: String
    ) throws -> [String: Any] {
        try waitForValue(timeout: timeout, description: description) {
            guard server.requestCount(method: method) > 0 else { return nil }
            return server.lastRequestParams(method: method) ?? [:]
        }
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval, description: String, condition: () -> Bool) throws -> Bool {
        try waitForValue(timeout: timeout, description: description) {
            condition() ? true : nil
        }
    }

    private func waitForCondition(timeout: TimeInterval, body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if body() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForValue<T>(timeout: TimeInterval, description: String, body: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(description)
        throw NSError(domain: "XCUITerminalCreationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
