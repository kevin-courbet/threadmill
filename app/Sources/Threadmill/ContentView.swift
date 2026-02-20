import SwiftUI

struct ContentView: View {
    @ObservedObject var connectionManager: ConnectionManager
    @ObservedObject var terminalBridge: TerminalBridge

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Threadmill")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(connectionManager.state.indicatorColor)
                    .frame(width: 10, height: 10)
                Text(connectionManager.state.displayText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ThreadmillTerminalView(bridge: terminalBridge)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            connectionManager.start()
            terminalBridge.attachIfNeeded()
        }
        .onDisappear {
            connectionManager.stop()
        }
        .onChange(of: connectionManager.state) { _, newState in
            switch newState {
            case .connected:
                terminalBridge.attachIfNeeded()
            case .disconnected, .connecting, .reconnecting:
                terminalBridge.resetAttachment()
            }
        }
    }
}
