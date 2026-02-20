import SwiftUI

@main
struct ThreadmillApp: App {
    @StateObject private var connectionManager: ConnectionManager
    @StateObject private var terminalBridge: TerminalBridge

    init() {
        let manager = ConnectionManager()
        _connectionManager = StateObject(wrappedValue: manager)
        _terminalBridge = StateObject(wrappedValue: TerminalBridge(connectionManager: manager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(connectionManager: connectionManager, terminalBridge: terminalBridge)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
