#!/usr/bin/env swift
// Creates a thread on Spindle for XCUI tests.
// Run before xcodebuild — the test runner is sandboxed and can't make network calls.

import Foundation

let url = URL(string: "ws://127.0.0.1:19990")!
let session = URLSession(configuration: .default)
let ws = session.webSocketTask(with: url)
ws.resume()

var nextID = 1

func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    let id = nextID; nextID += 1
    let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    let data = try JSONSerialization.data(withJSONObject: req)
    try await ws.send(.string(String(data: data, encoding: .utf8)!))
    while true {
        let msg = try await ws.receive()
        switch msg {
        case .string(let text):
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            if (json["id"] as? Int) == id { return json }
        default: continue
        }
    }
}

func main() async throws {
    // Handshake
    _ = try await rpc("session.hello", params: [
        "client": ["name": "xcui-setup", "version": "dev"],
        "protocol_version": "2026-03-17",
        "capabilities": ["state.delta.operations.v1", "preset.output.v1", "rpc.errors.structured.v1"]
    ])

    // Add fixture project
    _ = try await rpc("project.add", params: ["path": "/home/wsl/dev/threadmill-test-fixture"])
    let listResp = try await rpc("project.list", params: [:])
    let projects = listResp["result"] as! [[String: Any]]
    guard let project = projects.first(where: { ($0["path"] as? String)?.contains("test-fixture") == true }),
          let projectID = project["id"] as? String else {
        print("ERROR: fixture project not found")
        exit(1)
    }

    // Check if a test thread already exists
    let threadsResp = try await rpc("thread.list", params: [:])
    let threads = threadsResp["result"] as? [[String: Any]] ?? []
    let existing = threads.first(where: {
        ($0["project_id"] as? String) == projectID &&
        ($0["status"] as? String) == "active"
    })

    if let existing, let name = existing["name"] as? String {
        print("OK: thread '\(name)' already exists for fixture project")
        exit(0)
    }

    // Create one
    let name = "test-xcui-\(UUID().uuidString.prefix(8))"
    let createResp = try await rpc("thread.create", params: [
        "project_id": projectID, "name": name, "source_type": "new_feature"
    ])
    guard let result = createResp["result"] as? [String: Any],
          let threadID = result["id"] as? String else {
        print("ERROR: failed to create thread")
        exit(1)
    }

    // Wait for active
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        let msg = try await ws.receive()
        if case .string(let text) = msg,
           let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           json["method"] as? String == "thread.status_changed",
           let params = json["params"] as? [String: Any],
           (params["thread_id"] as? String) == threadID,
           (params["new"] as? String) == "active" {
            print("OK: created thread '\(name)' (\(threadID))")
            exit(0)
        }
    }
    print("ERROR: thread did not become active within 30s")
    exit(1)
}

Task { try await main() }
RunLoop.main.run(until: Date(timeIntervalSinceNow: 45))
print("ERROR: timed out")
exit(1)
