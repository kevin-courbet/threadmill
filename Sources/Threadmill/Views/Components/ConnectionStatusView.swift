import SwiftUI

struct ConnectionStatusView: View {
    let status: ConnectionStatus

    private var color: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .red
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
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .help(text)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("connection.status")
            .accessibilityLabel("Connection")
            .accessibilityValue(status.label)
    }
}
