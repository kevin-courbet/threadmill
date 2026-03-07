import SwiftUI

struct ConnectionStatusView: View {
    let status: ConnectionStatus

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
        Group {
            if status == .disconnected {
                HStack(spacing: 0) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.red)
                        .help(text)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("connection.status")
        .accessibilityLabel("Connection")
        .accessibilityValue(status.label)
    }
}
