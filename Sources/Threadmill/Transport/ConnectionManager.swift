import Foundation

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

enum ConnectionManagerError: LocalizedError {
    case invalidSessionHelloPayload
    case incompatibleProtocolVersion(expected: String, received: String)
    case missingRequiredServerCapabilities([String])
    case unsupportedServerRequiredCapabilities([String])

    var errorDescription: String? {
        switch self {
        case .invalidSessionHelloPayload:
            "session.hello returned an invalid payload."
        case let .incompatibleProtocolVersion(expected, received):
            "session.hello negotiated protocol \(received), expected \(expected)."
        case let .missingRequiredServerCapabilities(missing):
            "session.hello missing server capabilities required by Threadmill: \(missing.joined(separator: ", "))."
        case let .unsupportedServerRequiredCapabilities(missing):
            "session.hello requires client capabilities Threadmill does not support: \(missing.joined(separator: ", "))."
        }
    }
}

@MainActor
final class ConnectionManager: ConnectionManaging {
    private static let protocolVersion = "2026-03-17"
    private static let supportedCapabilities = [
        "state.delta.operations.v1",
        "preset.output.v1",
        "rpc.errors.structured.v1",
    ]
    private static let requiredServerCapabilities = Set(supportedCapabilities)
    private static let supportedCapabilitySet = Set(supportedCapabilities)

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

    private var binaryFrameHandler: ((Data) -> Void)?

    private var sessionID: String?
    private var negotiatedProtocolVersion: String?
    private var negotiatedCapabilities: Set<String> = []

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
            self?.handleInboundEvent(method: method, params: params)
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
        clearSessionContext()
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
        try await webSocketClient.sendRequest(method: method, params: params, timeout: timeout)
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
        NSLog("threadmill-conn: connecting (initial=%d)", initial ? 1 : 0)

        do {
            if config.useSSHTunnel {
                NSLog("threadmill-conn: starting SSH tunnel")
                try await tunnelManager.start()
                NSLog("threadmill-conn: SSH tunnel up")
            }

            guard let url = URL(string: "ws://\(config.webSocketHost):\(config.daemonPort)") else {
                state = .disconnected
                return
            }

            NSLog("threadmill-conn: connecting WebSocket to %@", url.absoluteString)
            webSocketClient.connect(to: url)

            NSLog("threadmill-conn: sending session.hello")
            try await performSessionHello()
            reconnectAttempt = 0
            state = .connected
            NSLog("threadmill-conn: CONNECTED")
            startPingLoop()
        } catch {
            NSLog("threadmill-conn: connect failed: %@", "\(error)")
            stopPingLoop()
            clearSessionContext()
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
        clearSessionContext()
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

    private func performSessionHello() async throws {
        let helloResult = try await request(method: "session.hello", params: sessionHelloParams(), timeout: 10)
        guard let payload = helloResult as? [String: Any],
              let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty,
              let protocolVersion = payload["protocol_version"] as? String,
              let capabilities = payload["capabilities"] as? [String],
              let stateVersion = parseStateVersion(payload["state_version"])
        else {
            throw ConnectionManagerError.invalidSessionHelloPayload
        }
        let requiredCapabilities = payload["required_capabilities"] as? [String] ?? capabilities

        guard protocolVersion == Self.protocolVersion else {
            throw ConnectionManagerError.incompatibleProtocolVersion(
                expected: Self.protocolVersion,
                received: protocolVersion
            )
        }

        let negotiatedCapabilities = Set(capabilities)
        let missingServerCapabilities = Array(Self.requiredServerCapabilities.subtracting(negotiatedCapabilities)).sorted()
        guard missingServerCapabilities.isEmpty else {
            throw ConnectionManagerError.missingRequiredServerCapabilities(missingServerCapabilities)
        }

        let unsupportedClientRequirements = Array(Set(requiredCapabilities).subtracting(Self.supportedCapabilitySet)).sorted()
        guard unsupportedClientRequirements.isEmpty else {
            throw ConnectionManagerError.unsupportedServerRequiredCapabilities(unsupportedClientRequirements)
        }

        self.sessionID = sessionID
        negotiatedProtocolVersion = protocolVersion
        self.negotiatedCapabilities = negotiatedCapabilities
        onEvent?("session.hello", ["state_version": stateVersion])
    }

    private func parseStateVersion(_ rawValue: Any?) -> Int? {
        if let value = rawValue as? Int, value >= 0 {
            return value
        }
        if let number = rawValue as? NSNumber {
            let value = number.intValue
            return value >= 0 ? value : nil
        }
        return nil
    }

    private func handleInboundEvent(method: String, params: [String: Any]?) {
        guard sessionID != nil else {
            return
        }
        onEvent?(method, params)
    }

    private func sessionHelloParams() -> [String: Any] {
        [
            "client": [
                "name": "threadmill-macos",
                "version": clientVersion,
            ],
            "protocol_version": Self.protocolVersion,
            "capabilities": Self.supportedCapabilities,
            "required_capabilities": Array(Self.requiredServerCapabilities).sorted(),
        ]
    }

    private var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func clearSessionContext() {
        sessionID = nil
        negotiatedProtocolVersion = nil
        negotiatedCapabilities.removeAll()
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
