import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddProjectSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingAddProjectSheet: $showingAddProjectSheet)
        } detail: {
            if appState.projects.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Add a repository to get started")
                        .font(.title3.weight(.semibold))
                    Button("Add Repository") {
                        showingAddProjectSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("empty-state.add-repository-button")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.selectedThread != nil {
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
        .sheet(isPresented: $showingAddProjectSheet) {
            AddProjectSheet()
        }
    }
}
