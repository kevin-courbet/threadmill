import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isBootstrapped = false
    private let connectionManager = ConnectionManager()
    private let ghosttyManager = GhosttyManager()

    private var databaseManager: DatabaseManager?
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
            let multiplexer = TerminalMultiplexer(connectionManager: connectionManager, ghosttyManager: ghosttyManager)
            let syncService = SyncService(
                connectionManager: connectionManager,
                databaseManager: databaseManager,
                appState: appState
            )

            self.databaseManager = databaseManager
            self.multiplexer = multiplexer
            self.syncService = syncService
            self.appState = appState

            appState.configure(
                connectionManager: connectionManager,
                databaseManager: databaseManager,
                syncService: syncService,
                multiplexer: multiplexer
            )
            appState.reloadFromDatabase()

            connectionManager.onStateChange = { [weak appState] status in
                appState?.connectionStatus = status
            }

            connectionManager.onConnected = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncService?.syncFromDaemon()
                }
            }

            connectionManager.onEvent = { [weak appState] method, params in
                appState?.handleDaemonEvent(method: method, params: params)
            }

            connectionManager.setBinaryFrameHandler { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.multiplexer?.handleBinaryFrame(data)
                }
            }

            appState.connectionStatus = connectionManager.state
            connectionManager.start()
            isBootstrapped = true
        } catch {
            fatalError("Failed to bootstrap Threadmill: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        Task { @MainActor [weak self] in
            self?.appState?.selectedEndpoint = nil
            self?.multiplexer?.detachAll()
            self?.connectionManager.stop()
            self?.ghosttyManager.shutdown()
        }
    }
}
