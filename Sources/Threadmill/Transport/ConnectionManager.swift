import Foundation
import os

enum ConnectionManagerError: LocalizedError {
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Connection to spindle is still negotiating session capabilities."
        }
    }
}

struct ThreadmillConfig {
    let host: String
    let daemonPort: Int
    let useSSHTunnel: Bool

    init(host: String, daemonPort: Int, useSSHTunnel: Bool) {
        self.host = host
        self.daemonPort = daemonPort
        self.useSSHTunnel = useSSHTunnel
    }

    init(remote: Remote) {
        self.host = remote.host
        self.daemonPort = remote.daemonPort
        self.useSSHTunnel = remote.useSSHTunnel
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> ThreadmillConfig {
        let host = environment["THREADMILL_HOST"] ?? "beast"
        let daemonPort = Int(environment["THREADMILL_DAEMON_PORT"] ?? "") ?? 19990
        let disableTunnel = (environment["THREADMILL_DISABLE_SSH_TUNNEL"] ?? "").lowercased()
        let useSSHTunnel = !(disableTunnel == "1" || disableTunnel == "true" || disableTunnel == "yes")
        return ThreadmillConfig(host: host, daemonPort: daemonPort, useSSHTunnel: useSSHTunnel)
    }

    var webSocketHost: String {
        useSSHTunnel ? "127.0.0.1" : host
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)

    var label: String {
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

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

@MainActor
final class ConnectionManager: ConnectionManaging {
    private enum SessionHandshake {
        static let protocolVersion = "2026-03-17"
        static let capabilities = [
            "state.delta.operations.v1",
            "preset.output.v1",
            "rpc.errors.structured.v1",
        ]
    }

    private let config: ThreadmillConfig

    private(set) var state: ConnectionStatus = .disconnected {
        didSet {
            guard oldValue != state else {
                return
            }
            onStateChange?(state)
            if case .connected = state {
                onConnected?()
            }
        }
    }

    var onStateChange: ((ConnectionStatus) -> Void)?
    var onConnected: (() -> Void)?
    var onEvent: ((String, [String: Any]?) -> Void)?

    let tunnelManager: any TunnelManaging
    let webSocketClient: any WebSocketManaging

    private let maxReconnectAttempts: Int
    private let reconnectDelay: (Int) -> TimeInterval
    private var reconnectAttempt = 0
    private var shouldRun = false
    private var isConnecting = false

    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var sessionReady = false
    private var lastErrorDescription: String?

    private var binaryFrameHandler: ((Data) -> Void)?

    var debugSnapshot: ConnectionDebugSnapshot {
        ConnectionDebugSnapshot(
            status: state.label,
            sessionReady: sessionReady,
            reconnectAttempt: reconnectAttempt,
            lastErrorDescription: lastErrorDescription
        )
    }

    init(
        config: ThreadmillConfig = .load(),
        tunnelManager: (any TunnelManaging)? = nil,
        webSocketClient: (any WebSocketManaging)? = nil,
        maxReconnectAttempts: Int = 8,
        reconnectDelay: @escaping (Int) -> TimeInterval = { attempt in
            min(pow(2.0, Double(attempt - 1)), 30.0)
        }
    ) {
        self.config = config
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
        self.tunnelManager = tunnelManager ?? SSHTunnelManager(
            host: config.host,
            localPort: config.daemonPort,
            remotePort: config.daemonPort
        )
        self.webSocketClient = webSocketClient ?? WebSocketClient()

        self.tunnelManager.onExit = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTransportDrop()
            }
        }

        self.webSocketClient.onBinaryMessage = { [weak self] data in
            self?.binaryFrameHandler?(data)
        }

        self.webSocketClient.onEvent = { [weak self] method, params in
            self?.onEvent?(method, params)
        }

        self.webSocketClient.onDisconnect = { [weak self] _ in
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
        cancelScheduledReconnect()

        Task {
            await connect(initial: true)
        }
    }

    func stop() {
        shouldRun = false
        cancelScheduledReconnect()
        stopPingLoop()
        sessionReady = false
        lastErrorDescription = nil
        webSocketClient.disconnect()
        tunnelManager.stop()
        state = .disconnected
    }

    func cancelScheduledReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
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
        let bypassHandshake = method == "ping" || method == "session.hello"
        guard bypassHandshake || sessionReady else {
            throw ConnectionManagerError.sessionNotReady
        }
        return try await webSocketClient.sendRequest(method: method, params: params, timeout: timeout)
    }

    private func connect(initial: Bool) async {
        guard shouldRun else {
            return
        }

        guard !isConnecting else {
            return
        }

        isConnecting = true
        defer {
            isConnecting = false
        }

        state = initial ? .connecting : .reconnecting(attempt: reconnectAttempt)
        Logger.conn.info("Connecting (initial=\(initial, privacy: .public))")

        do {
            if config.useSSHTunnel {
                Logger.conn.info("Starting SSH tunnel")
                try await tunnelManager.start()
                Logger.conn.info("SSH tunnel up")
            }

            guard let url = URL(string: "ws://\(config.webSocketHost):\(config.daemonPort)") else {
                state = .disconnected
                return
            }

            Logger.conn.info("Connecting WebSocket to \(url.absoluteString, privacy: .public)")
            webSocketClient.connect(to: url)

            Logger.conn.info("Sending ping")
            _ = try await request(method: "ping", timeout: 10)
            Logger.conn.info("Negotiating session")
            _ = try await request(
                method: "session.hello",
                params: [
                    "client": [
                        "name": "threadmill",
                        "version": "dev",
                    ],
                    "protocol_version": SessionHandshake.protocolVersion,
                    "capabilities": SessionHandshake.capabilities,
                ],
                timeout: 10
            )
            reconnectAttempt = 0
            sessionReady = true
            lastErrorDescription = nil
            state = .connected
            Logger.conn.notice("CONNECTED")
            startPingLoop()
        } catch {
            Logger.conn.error("Connect failed: \(error)")
            stopPingLoop()
            sessionReady = false
            lastErrorDescription = String(describing: error)
            webSocketClient.disconnect()
            if config.useSSHTunnel {
                tunnelManager.stop()
            }
            scheduleReconnect()
        }
    }

    private func handleTransportDrop() {
        guard shouldRun else {
            return
        }

        guard !isConnecting else {
            return
        }

        guard state != .disconnected else {
            return
        }

        if case .reconnecting = state {
            return
        }

        state = .disconnected
        stopPingLoop()
        sessionReady = false
        lastErrorDescription = "transport dropped"
        webSocketClient.disconnect()
        if config.useSSHTunnel {
            tunnelManager.stop()
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun else {
            state = .disconnected
            return
        }

        cancelScheduledReconnect()

        guard reconnectAttempt < maxReconnectAttempts else {
            state = .disconnected
            return
        }

        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)

        let delaySeconds = reconnectDelay(reconnectAttempt)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }
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
