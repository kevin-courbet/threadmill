import AppKit
import ApplicationServices
import Foundation
import XCTest

final class ThreadmillUITests: XCTestCase {
    func testMacOSUIE2EFlowWithReconnect() throws {
        guard ProcessInfo.processInfo.environment["THREADMILL_RUN_UI_E2E"] == "1" else {
            throw XCTSkip("Set THREADMILL_RUN_UI_E2E=1 to run macOS UI E2E test")
        }

        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is required for UI E2E tests")
        }

        let mockServer = MockSpindleServer()
        try mockServer.start()
        defer {
            mockServer.stop()
        }

        let appPath = try locateThreadmillExecutable()
        let dbRoot = URL(fileURLWithPath: "/tmp/threadmill-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dbRoot)
        }

        let appProcess = Process()
        appProcess.executableURL = appPath
        appProcess.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        appProcess.environment = launchEnvironment(port: mockServer.port, dbPath: dbRoot.appendingPathComponent("threadmill.db").path)
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

    private func launchEnvironment(port: UInt16, dbPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["THREADMILL_DISABLE_SSH_TUNNEL"] = "1"
        environment["THREADMILL_HOST"] = "127.0.0.1"
        environment["THREADMILL_DAEMON_PORT"] = "\(port)"
        environment["THREADMILL_DB_PATH"] = dbPath
        environment["THREADMILL_USE_MOCK_TERMINAL"] = "1"
        environment["THREADMILL_UI_TEST_MODE"] = "1"
        return environment
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
