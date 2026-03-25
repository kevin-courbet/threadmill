import ACPModel
import Foundation
import os
import OSLog
import XCTest
@testable import Threadmill

/// Base class for Spindle integration tests.
/// Provides connection helpers, thread lifecycle management, and ACP session setup.
/// Sweeps stale test- threads on first run, cleans up created threads in tearDown.
///
/// On test failure, automatically dumps all `dev.threadmill` os.Logger output
/// captured during the test to stdout via OSLogStore. This makes structured
/// logs visible in `swift test --verbose` output for Red-phase debugging.
class IntegrationTestCase: XCTestCase {
    static let fixtureRepoPath = "/home/wsl/dev/threadmill-test-fixture"
    static let testPrefix = "test-"

    private nonisolated(unsafe) static var hasSweptStaleThreads = false
    var createdThreadIDs: [String] = []
    private nonisolated(unsafe) var logStore: OSLogStore?
    private nonisolated(unsafe) var testStartDate: Date?

    override func setUp() async throws {
        try await super.setUp()

        testStartDate = Date()
        logStore = try? OSLogStore(scope: .currentProcessIdentifier)

        if !Self.hasSweptStaleThreads {
            Self.hasSweptStaleThreads = true
            let conn = SpindleConnection()
            defer { conn.disconnect() }
            try await conn.connect()
            try await conn.handshake()
            if let threads = try await conn.rpc("thread.list", params: nil) as? [[String: Any]] {
                for thread in threads {
                    guard let name = thread["name"] as? String, name.hasPrefix(Self.testPrefix),
                          let threadID = thread["id"] as? String
                    else {
                        continue
                    }
                    _ = try? await conn.rpc(
                        "thread.close",
                        params: ["thread_id": threadID, "mode": "close"],
                        timeout: 30
                    )
                }
            }
        }
    }

    override func tearDown() async throws {
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            dumpThreadmillLogs()
        }

        let threadIDs = createdThreadIDs
        createdThreadIDs.removeAll()

        if !threadIDs.isEmpty {
            let conn = SpindleConnection()
            defer { conn.disconnect() }
            do {
                try await conn.connect()
                try await conn.handshake()
                for threadID in threadIDs {
                    _ = try? await conn.rpc(
                        "thread.close",
                        params: ["thread_id": threadID, "mode": "close"],
                        timeout: 30
                    )
                }
            } catch {
                // Don't fail the test for cleanup errors — the next run's sweep handles it
            }
        }

        try await super.tearDown()
    }

    // MARK: - Connection

    func makeConnection() async throws -> SpindleConnection {
        let conn = SpindleConnection()
        try await conn.connect()
        try await conn.handshake()
        return conn
    }

    // MARK: - Project

    func ensureProjectID(conn: SpindleConnection) async throws -> String {
        _ = try? await conn.rpc("project.add", params: ["path": Self.fixtureRepoPath], timeout: 20)
        let projectsResult = try await conn.rpc("project.list", params: nil)
        let projects = try XCTUnwrap(projectsResult as? [[String: Any]])
        let project = try XCTUnwrap(projects.first(where: { ($0["path"] as? String) == Self.fixtureRepoPath }))
        return try XCTUnwrap(project["id"] as? String)
    }

    // MARK: - Thread

    func createThread(conn: SpindleConnection) async throws -> String {
        let projectID = try await ensureProjectID(conn: conn)
        let threadName = uniqueThreadName()
        let result = try await conn.rpc(
            "thread.create",
            params: [
                "project_id": projectID,
                "name": threadName,
                "source_type": "new_feature",
            ],
            timeout: 30
        )
        let payload = try XCTUnwrap(result as? [String: Any])
        let threadID = try XCTUnwrap(payload["id"] as? String)
        createdThreadIDs.append(threadID)

        try await waitForThreadActive(conn: conn, threadID: threadID)
        return threadID
    }

    func waitForThreadActive(conn: SpindleConnection, threadID: String, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let event = try await conn.waitForEvent("thread.status_changed", timeout: 5)
            if (event["thread_id"] as? String) == threadID,
               (event["new"] as? String) == "active" {
                return
            }
        }
        throw SpindleConnectionError.timedOut("thread \(threadID) becoming active")
    }

    func uniqueThreadName() -> String {
        "\(Self.testPrefix)integration-\(UUID().uuidString.prefix(8))"
    }

    // MARK: - ACP

    /// Starts an ACP agent on beast, performs initialize + session/new handshake.
    /// Returns (channelID, acpSessionID). Registers addTeardownBlock for agent.stop.
    func startACPSession(conn: SpindleConnection) async throws -> (channelID: UInt16, sessionID: String) {
        let projectID = try await ensureProjectID(conn: conn)
        let startResult = try await conn.rpc(
            "agent.start",
            params: ["project_id": projectID, "agent_name": "opencode"],
            timeout: 30
        )
        let startPayload = try XCTUnwrap(startResult as? [String: Any])
        let channelIDRaw = try XCTUnwrap(startPayload["channel_id"] as? Int)
        let channelID = UInt16(channelIDRaw)

        addTeardownBlock {
            _ = try? await conn.rpc("agent.stop", params: ["channel_id": channelIDRaw], timeout: 20)
        }

        let initReq = try makeACPRequest(
            id: 1,
            method: "initialize",
            params: InitializeRequest(
                protocolVersion: 1,
                clientCapabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                    terminal: false
                ),
                clientInfo: ClientInfo(name: "ThreadmillTests", title: "ThreadmillTests", version: "dev")
            )
        )
        try await conn.sendBinary(makeACPFrame(channelID: channelID, payload: initReq))
        let initResp = try await waitForACPLine(conn: conn, channelID: channelID, timeout: 15) {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        }
        XCTAssertNotNil(initResp["result"], "ACP initialize failed")

        let newReq = try makeACPRequest(id: 2, method: "session/new", params: NewSessionRequest(cwd: "."))
        try await conn.sendBinary(makeACPFrame(channelID: channelID, payload: newReq))
        let newResp = try await waitForACPLine(conn: conn, channelID: channelID, timeout: 15) {
            ($0["id"] as? Int) == 2 || ($0["id"] as? String) == "2"
        }
        let sessionResult = try XCTUnwrap(newResp["result"] as? [String: Any])
        let sessionID = try XCTUnwrap(sessionResult["sessionId"] as? String)

        return (channelID, sessionID)
    }

    // MARK: - Frame helpers

    func makeACPFrame(channelID: UInt16, payload: Data) -> Data {
        var frame = Data([UInt8(channelID >> 8), UInt8(channelID & 0xFF)])
        frame.append(payload)
        frame.append(0x0A)
        return frame
    }

    func makeACPRequest<Params: Encodable>(id: Int, method: String, params: Params) throws -> Data {
        try JSONEncoder().encode(ACPRequestPayload(id: id, method: method, params: params))
    }

    func waitForACPLine(
        conn: SpindleConnection,
        channelID: UInt16,
        timeout: TimeInterval,
        predicate: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()

        while Date() < deadline {
            let frame: Data
            do {
                frame = try await conn.waitForBinaryFrame(channelID: channelID, timeout: 2.0)
            } catch {
                continue
            }
            buffer.append(frame.dropFirst(2))

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)

                guard !line.isEmpty else {
                    continue
                }

                let object = try JSONSerialization.jsonObject(with: line)
                guard let json = object as? [String: Any] else {
                    continue
                }

                if predicate(json) {
                    return json
                }
            }
        }

        throw SpindleConnectionError.timedOut("ACP line")
    }

    func waitForTerminalOutput(
        conn: SpindleConnection,
        channelID: UInt16,
        contains expected: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var aggregate = ""

        while Date() < deadline {
            let frame: Data
            do {
                frame = try await conn.waitForBinaryFrame(channelID: channelID, timeout: 2.0)
            } catch {
                continue
            }
            let payload = Data(frame.dropFirst(2))
            aggregate.append(String(decoding: payload, as: UTF8.self))
            if aggregate.contains(expected) {
                return aggregate
            }
        }

        throw SpindleConnectionError.timedOut("terminal output containing \(expected)")
    }

    // MARK: - SSH

    func runSSH(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["beast", command]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Utilities

    static func findTextInJSON(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, val) in dict {
                if key == "text", let str = val as? String,
                   !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                if findTextInJSON(val) { return true }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if findTextInJSON(item) { return true }
            }
        }
        return false
    }

    func makeTempDatabasePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threadmill-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("threadmill.db", isDirectory: false).path
    }

    // MARK: - Log capture

    /// Dumps all dev.threadmill os.Logger output from test start to now.
    /// Called automatically on test failure via addTeardownBlock.
    private func dumpThreadmillLogs() {
        guard let logStore, let testStartDate else {
            return
        }

        do {
            let position = logStore.position(date: testStartDate)
            let predicate = NSPredicate(format: "subsystem == 'dev.threadmill'")
            let entries = try logStore.getEntries(at: position, matching: predicate)

            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else {
                    continue
                }
                let level: String
                switch log.level {
                case .debug: level = "DEBUG"
                case .info: level = "INFO"
                case .notice: level = "NOTICE"
                case .error: level = "ERROR"
                case .fault: level = "FAULT"
                default: level = "LOG"
                }
                lines.append("  [\(log.category)] \(level): \(log.composedMessage)")
            }

            if lines.isEmpty {
                print("--- threadmill logs: (none captured) ---")
            } else {
                print("--- threadmill logs (\(lines.count) entries) ---")
                for line in lines {
                    print(line)
                }
                print("--- end threadmill logs ---")
            }
        } catch {
            print("--- threadmill logs: OSLogStore query failed: \(error) ---")
        }
    }

    /// Manually dump logs for a specific category. Useful in test body for debugging.
    func dumpLogs(category: String? = nil) {
        guard let logStore, let testStartDate else {
            return
        }

        do {
            let position = logStore.position(date: testStartDate)
            let predicate: NSPredicate
            if let category {
                predicate = NSPredicate(format: "subsystem == 'dev.threadmill' AND category == %@", category)
            } else {
                predicate = NSPredicate(format: "subsystem == 'dev.threadmill'")
            }
            let entries = try logStore.getEntries(at: position, matching: predicate)

            for entry in entries {
                guard let log = entry as? OSLogEntryLog else {
                    continue
                }
                print("  [\(log.category)] \(log.composedMessage)")
            }
        } catch {
            print("OSLogStore query failed: \(error)")
        }
    }
}
