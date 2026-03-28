import AppKit
import Foundation
import XCTest

@MainActor
final class ThreadmillUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["THREADMILL_RUN_UI_E2E"] == "1" else {
            throw XCTSkip("Set THREADMILL_RUN_UI_E2E=1 to run AX e2e tests")
        }
    }

    func testChatSessionLifecycle() async throws {
        let mockServer = MockSpindleServer()
        try await mockServer.start()
        defer { mockServer.stop() }
        let port = try XCTUnwrap(mockServer.port)

        let dbPath = try makeTempDatabasePath()
        let app = try launchThreadmill(daemonPort: port, dbPath: dbPath)
        defer { app.forceTerminate() }

        let ax = AXTestClient(pid: app.processIdentifier)

        _ = await mockServer.waitForRPC(method: "session.hello", timeout: 10)
        _ = await mockServer.waitForRPC(method: "project.list", timeout: 10)

        try ax.click(identifier: "thread.row.thread-chat-fixture", timeout: 10)
        try ax.click(identifier: "mode.tab.chat", timeout: 10)

        try ax.waitForLabel("OpenCode", timeout: 10)
        try ax.waitForValueContains(identifier: "chat.session.state", value: "ready", timeout: 10)

        let modelLabel = ax.value(for: "chat.model.label") ?? ""
        XCTAssertFalse(modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(modelLabel, "Model")

        try ax.setText("Hello from UI test", identifier: "chat.input", timeout: 10)
        ax.keyReturn()

        let receivedPrompt = await mockServer.waitForPrompt(containing: "Hello from UI test", timeout: 10)
        XCTAssertTrue(receivedPrompt, "Mock server never received session/prompt payload")

        try ax.waitForValueContains(
            identifier: "chat.timeline",
            value: "Mock response: Hello from UI test",
            timeout: 10
        )
    }

    private func launchThreadmill(daemonPort: Int, dbPath: String) throws -> NSRunningApplication {
        final class LaunchBox: @unchecked Sendable {
            var app: NSRunningApplication?
            var error: Error?
        }

        let appURL = try locateAppBundle()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.environment = [
            "THREADMILL_DISABLE_SSH_TUNNEL": "1",
            "THREADMILL_HOST": "127.0.0.1",
            "THREADMILL_DAEMON_PORT": String(daemonPort),
            "THREADMILL_DB_PATH": dbPath,
            "THREADMILL_USE_MOCK_TERMINAL": "1",
        ]

        let sem = DispatchSemaphore(value: 0)
        let launchBox = LaunchBox()

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            launchBox.app = app
            launchBox.error = error
            sem.signal()
        }

        guard sem.wait(timeout: .now() + 10) == .success else {
            throw MockServerError("Timed out launching Threadmill.app")
        }
        if let launchError = launchBox.error {
            throw launchError
        }
        guard let launched = launchBox.app else {
            throw MockServerError("Threadmill.app launch returned nil process")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if launched.isTerminated {
                throw MockServerError("Threadmill.app terminated during launch")
            }
            if launched.activationPolicy != .prohibited {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return launched
    }

    private func makeTempDatabasePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-ui-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }

    private func locateAppBundle() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            ".build/debug/Threadmill.app",
            ".build/arm64-apple-macosx/debug/Threadmill.app",
        ]

        for candidate in candidates {
            let url = root.appendingPathComponent(candidate, isDirectory: true)
            let executable = url.appendingPathComponent("Contents/MacOS/Threadmill")
            if FileManager.default.fileExists(atPath: executable.path) {
                return url
            }
        }

        throw XCTSkip("Threadmill.app not built. Run: task app:bundle")
    }
}
