import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if appState.selectedThread != nil {
                ThreadDetailView()
            } else {
                ContentUnavailableView(
                    "Select a Thread",
                    systemImage: "terminal",
                    description: Text("Choose a thread from the sidebar to open terminal presets.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ConnectionStatusView(status: appState.connectionStatus)
            }
        }
    }
}
