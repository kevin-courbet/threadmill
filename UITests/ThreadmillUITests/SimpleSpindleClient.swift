import Foundation
import os

/// Minimal WebSocket client for Spindle RPCs in XCUI tests.
final class SimpleSpindleClient: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 1
    private var receivedEvents: [(String, [String: Any]?)] = []
    private var receiveLoopTask: Task<Void, Never>?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func connect() async throws -> SimpleSpindleClient {
        let client = SimpleSpindleClient()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:19990")!)
        client.session = session
        client.task = task
        task.resume()
        client.receiveLoopTask = Task { await client.receiveLoop() }

        _ = try await client.rpc("session.hello", params: [
            "client": ["name": "xcui-test", "version": "dev"],
            "protocol_version": "2026-03-17",
            "capabilities": ["state.delta.operations.v1", "preset.output.v1", "rpc.errors.structured.v1"],
        ])

        return client
    }

    func rpc(_ method: String, params: [String: Any]?, timeout: TimeInterval = 20) async throws -> Any {
        guard let task else {
            throw NSError(domain: "SimpleSpindleClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let requestID = withLock {
            let id = nextID
            nextID += 1
            return id
        }

        var request: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method]
        if let params { request["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: request)
        let string = String(data: data, encoding: .utf8)!

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.fail(requestID, error: NSError(domain: "SimpleSpindleClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout: \(method)"]))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            self.withLock { self.pendingRequests[requestID] = continuation }
            Task { try await task.send(.string(string)) }
        }
    }

    func waitForEvent(_ method: String, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let params = withLock({
                guard let idx = receivedEvents.firstIndex(where: { $0.0 == method }) else { return nil as [String: Any]?? }
                return receivedEvents.remove(at: idx).1
            }) {
                return params ?? [:]
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "SimpleSpindleClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for \(method)"])
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        let continuations = withLock {
            let vals = Array(pendingRequests.values)
            pendingRequests.removeAll()
            return vals
        }
        for c in continuations {
            c.resume(throwing: NSError(domain: "SimpleSpindleClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let text):
                    guard let data = text.data(using: .utf8),
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let id = json["id"] as? Int {
                        let cont = withLock { pendingRequests.removeValue(forKey: id) }
                        if let error = json["error"] as? [String: Any] {
                            cont?.resume(throwing: NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "RPC error"]))
                        } else {
                            let result = json["result"] ?? json as Any
                            nonisolated(unsafe) let r = result
                            cont?.resume(returning: r)
                        }
                    } else if let method = json["method"] as? String {
                        withLock {
                            receivedEvents.append((method, json["params"] as? [String: Any]))
                            if receivedEvents.count > 200 { receivedEvents.removeFirst(receivedEvents.count - 200) }
                        }
                    }
                default: break
                }
            } catch {
                return
            }
        }
    }

    private func fail(_ id: Int, error: Error) {
        let cont = withLock { pendingRequests.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }
}
