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
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.red)
                    .help(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection")
        .accessibilityValue(status.label)
    }
}
