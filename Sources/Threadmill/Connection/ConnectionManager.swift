import Foundation
import SwiftUI

struct ThreadmillConfig {
    static let host = "beast"
    static let daemonPort = 19990
    static let testSession = "threadmill-test:0.0"
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)

    var displayText: String {
        switch self {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case let .reconnecting(attempt):
            "reconnecting (\(attempt))"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected:
            .green
        case .connecting, .reconnecting:
            .orange
        case .disconnected:
            .secondary
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

@MainActor
final class ConnectionManager: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected

    let tunnelManager: SSHTunnelManager
    let webSocketClient: WebSocketClient

    private let maxReconnectAttempts = 8
    private var reconnectAttempt = 0
    private var shouldRun = false

    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private var binaryFrameHandler: ((Data) -> Void)?

    init() {
        tunnelManager = SSHTunnelManager(
            host: ThreadmillConfig.host,
            localPort: ThreadmillConfig.daemonPort,
            remotePort: ThreadmillConfig.daemonPort
        )
        webSocketClient = WebSocketClient()

        tunnelManager.onExit = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTransportDrop()
            }
        }

        webSocketClient.onBinaryMessage = { [weak self] data in
            self?.binaryFrameHandler?(data)
        }

        webSocketClient.onDisconnect = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTransportDrop()
            }
        }
    }

    func start() {
        guard !shouldRun else {
            return
        }

        shouldRun = true
        reconnectAttempt = 0
        reconnectTask?.cancel()

        Task {
            await connect(initial: true)
        }
    }

    func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPingLoop()
        webSocketClient.disconnect()
        tunnelManager.stop()
        state = .disconnected
    }

    func markConnected() {
        reconnectAttempt = 0
        state = .connected
        shouldRun = true
    }

    func setBinaryFrameHandler(_ handler: ((Data) -> Void)?) {
        binaryFrameHandler = handler
    }

    func sendBinaryFrame(_ data: Data) async throws {
        try await webSocketClient.sendBinaryFrame(data)
    }

    func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Any {
        try await webSocketClient.sendRequest(method: method, params: params, timeout: timeout)
    }

    private func connect(initial: Bool) async {
        guard shouldRun else {
            return
        }

        state = initial ? .connecting : .reconnecting(attempt: reconnectAttempt)
        NSLog("threadmill-conn: connecting (initial=%d)", initial ? 1 : 0)

        do {
            NSLog("threadmill-conn: starting SSH tunnel")
            try await tunnelManager.start()
            NSLog("threadmill-conn: SSH tunnel up")

            guard let url = URL(string: "ws://127.0.0.1:\(ThreadmillConfig.daemonPort)") else {
                state = .disconnected
                return
            }

            NSLog("threadmill-conn: connecting WebSocket to %@", url.absoluteString)
            webSocketClient.connect(to: url)

            NSLog("threadmill-conn: sending ping")
            _ = try await request(method: "ping", timeout: 10)
            reconnectAttempt = 0
            state = .connected
            NSLog("threadmill-conn: CONNECTED")
            startPingLoop()
        } catch {
            NSLog("threadmill-conn: connect failed: %@", "\(error)")
            stopPingLoop()
            webSocketClient.disconnect()
            tunnelManager.stop()
            scheduleReconnect()
        }
    }

    private func handleTransportDrop() {
        guard shouldRun else {
            return
        }

        stopPingLoop()
        webSocketClient.disconnect()
        tunnelManager.stop()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun else {
            state = .disconnected
            return
        }

        reconnectTask?.cancel()

        guard reconnectAttempt < maxReconnectAttempts else {
            state = .disconnected
            return
        }

        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)

        let delaySeconds = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self?.connect(initial: false)
        }
    }

    private func startPingLoop() {
        stopPingLoop()

        pingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled {
                    return
                }

                do {
                    _ = try await self.request(method: "ping", timeout: 10)
                } catch {
                    await MainActor.run {
                        self.handleTransportDrop()
                    }
                    return
                }
            }
        }
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
    }
}
