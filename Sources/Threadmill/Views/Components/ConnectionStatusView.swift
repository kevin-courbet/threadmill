import SwiftUI

struct ConnectionStatusView: View {
    let status: ConnectionStatus

    private var icon: String {
        switch status {
        case .connected:
            return "🟢"
        case .connecting, .reconnecting:
            return "🟡"
        case .disconnected:
            return "🔴"
        }
    }

    private var text: String {
        switch status {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .reconnecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(icon)
            Text(text)
                .font(.caption)
        }
    }
}
