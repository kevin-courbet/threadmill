import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isBootstrapped = false
    private let surfaceHost = GhosttySurfaceHost()
    private let openCodeClient = OpenCodeClient()

    private var remoteConnectionPool: RemoteConnectionPool?
    private var primaryConnectionManager: (any ConnectionManaging)?
    private var databaseManager: DatabaseManager?
    private var provisioningService: ProvisioningService?
    private var chatConversationService: ChatConversationService?
    private var syncService: SyncService?
    private var multiplexer: TerminalMultiplexer?
    private weak var appState: AppState?

    func applicationWillFinishLaunching(_: Notification) {
        // SPM executables don't get activation policy from an app bundle automatically
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.activate(ignoringOtherApps: true)
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
                NSLog("threadmill-bootstrap: failed to sync remotes from config file: %@", "\(error)")
            }

            let defaultRemote = try databaseManager.ensureDefaultRemoteExists()
            let remotes = try databaseManager.allRemotes()
            let effectiveRemotes = remotes.isEmpty ? [defaultRemote] : remotes

            let selectedRemote = effectiveRemotes.first(where: { $0.name == DatabaseManager.RemoteDefaults.beastName }) ?? defaultRemote
            let connectionPool = RemoteConnectionPool(remotes: effectiveRemotes, activeRemoteId: selectedRemote.id)
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
                databaseManager: databaseManager,
                openCodeClient: openCodeClient
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
                openCodeClient: openCodeClient,
                chatConversationService: chatConversationService
            )
            appState.reloadFromDatabase()

            if let concreteConnectionManager = primaryConnectionManager as? ConnectionManager {
                concreteConnectionManager.onStateChange = { [weak appState] status in
                    appState?.connectionStatus = status
                }

                concreteConnectionManager.onConnected = { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.multiplexer?.reattachAll()
                        await self?.syncService?.syncFromDaemon()
                    }
                }

                concreteConnectionManager.onEvent = { [weak appState] method, params in
                    appState?.handleDaemonEvent(method: method, params: params)
                }

                concreteConnectionManager.setBinaryFrameHandler { [weak self] data in
                    Task { @MainActor [weak self] in
                        self?.multiplexer?.handleBinaryFrame(data)
                    }
                }
            }

            appState.connectionStatus = primaryConnectionManager.state
            primaryConnectionManager.start()
            isBootstrapped = true
        } catch {
            fatalError("Failed to bootstrap Threadmill: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        Task { @MainActor [weak self] in
            self?.appState?.selectedEndpoint = nil
            self?.multiplexer?.detachAll()
            self?.remoteConnectionPool?.stopAll()
            self?.surfaceHost.shutdown()
        }
    }
}
