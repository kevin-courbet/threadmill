import SwiftUI

struct TerminalTabView: View {
    let endpoint: RelayEndpoint?

    var body: some View {
        Group {
            if let endpoint {
                GhosttyTerminalView(endpoint: endpoint)
            } else {
                ContentUnavailableView(
                    "Connecting Terminal",
                    systemImage: "bolt.horizontal",
                    description: Text("Attach to a preset to start terminal streaming.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
