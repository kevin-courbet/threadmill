import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isBootstrapped = false
    private let surfaceHost = GhosttySurfaceHost()

    private var remoteConnectionPool: RemoteConnectionPool?
    private var primaryConnectionManager: (any ConnectionManaging)?
    private var databaseManager: DatabaseManager?
    private var provisioningService: ProvisioningService?
    private var chatConversationService: ChatConversationService?
    private var agentSessionManager: AgentSessionManager?
    private var syncService: SyncService?
    private var multiplexer: TerminalMultiplexer?
    private weak var appState: AppState?

    func applicationWillFinishLaunching(_: Notification) {
        // SPM executables don't get activation policy from an app bundle automatically
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Logger.boot.info("applicationDidFinishLaunching — args: \(ProcessInfo.processInfo.arguments, privacy: .public)")
        Logger.boot.info("env THREADMILL keys: \(ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("THREADMILL") }, privacy: .public)")
    }

    func bootstrap(appState: AppState) {
        guard !isBootstrapped else {
            return
        }

        do {
            let databaseManager = try DatabaseManager()

            do {
                try databaseManager.syncRemotesFromConfigFile()
            } catch {
                Logger.boot.error("Failed to sync remotes from config file: \(error)")
            }

            let defaultRemote = try databaseManager.ensureDefaultRemoteExists()
            let remotes = try databaseManager.allRemotes()
            let effectiveRemotes = remotes.isEmpty ? [defaultRemote] : remotes

            let selectedRemote = effectiveRemotes.first(where: \.isDefault) ?? defaultRemote
            let connectionPool = RemoteConnectionPool(
                remotes: effectiveRemotes,
                activeRemoteId: selectedRemote.id,
                onConnectionCreated: { [weak self, weak appState] connection in
                    guard let self, let appState else {
                        return
                    }
                    self.configureConnectionHandlers(for: connection, appState: appState)
                }
            )
            guard let primaryConnectionManager = connectionPool.connection(for: selectedRemote.id) else {
                fatalError("Failed to bootstrap Threadmill: default remote connection unavailable")
            }

            let multiplexer = TerminalMultiplexer(
                connectionResolver: { [weak appState] threadID in
                    appState?.connectionForThread(id: threadID)
                },
                surfaceHost: surfaceHost
            )
            let syncService = SyncService(
                connectionManager: primaryConnectionManager,
                databaseManager: databaseManager,
                appState: appState,
                remoteId: selectedRemote.id
            )
            let provisioningService = ProvisioningService(connectionPool: connectionPool)
            let chatConversationService = ChatConversationService(
                databaseManager: databaseManager
            )
            agentSessionManager = AgentSessionManager(
                connectionManager: primaryConnectionManager
            )

            self.databaseManager = databaseManager
            remoteConnectionPool = connectionPool
            self.primaryConnectionManager = primaryConnectionManager
            self.multiplexer = multiplexer
            self.syncService = syncService
            self.provisioningService = provisioningService
            self.chatConversationService = chatConversationService
            self.appState = appState

            appState.configure(
                connectionPool: connectionPool,
                databaseManager: databaseManager,
                syncService: syncService,
                multiplexer: multiplexer,
                provisioningService: provisioningService,
                chatConversationService: chatConversationService,
                agentSessionManager: agentSessionManager
            )
            appState.reloadFromDatabase()

            appState.connectionStatus = primaryConnectionManager.state
            primaryConnectionManager.start()
            isBootstrapped = true
        } catch {
            fatalError("Failed to bootstrap Threadmill: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        Task { @MainActor [weak self] in
            self?.appState?.shutdown()
            self?.appState?.selectedEndpoint = nil
            self?.multiplexer?.detachAll()
            self?.remoteConnectionPool?.stopAll()
            self?.surfaceHost.shutdown()
        }
    }

    private func configureConnectionHandlers(for connection: any ConnectionManaging, appState: AppState) {
        connection.onStateChange = { [weak self, weak appState] status in
            appState?.connectionStatus = status
            self?.agentSessionManager?.handleConnectionStateChanged(status, on: connection)
        }

        connection.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                Logger.conn.info("onConnected — starting reattach + sync")
                await self?.multiplexer?.reattachAll()
                await self?.syncService?.syncFromDaemon()
                await self?.agentSessionManager?.handleConnectionReconnected(on: connection)
                Logger.conn.info("onConnected — sync complete")
            }
        }

        connection.onEvent = { [weak appState] method, params in
            appState?.handleDaemonEvent(method: method, params: params)
        }

        connection.setBinaryFrameHandler { [weak self] data in
            Task { @MainActor [weak self] in
                self?.multiplexer?.handleBinaryFrame(data)
                self?.agentSessionManager?.handleBinaryFrame(data, from: connection)
            }
        }
    }
}
