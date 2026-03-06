import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddRepoSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingAddRepoSheet: $showingAddRepoSheet)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            if appState.repos.isEmpty && appState.projects.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Add a repository to get started")
                        .font(.title3.weight(.semibold))
                    Button("Add Repository") {
                        showingAddRepoSheet = true
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConnectionStatusView(status: appState.connectionStatus)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Bindable(appState).isNewThreadSheetPresented) {
            if let repo = appState.repos.first {
                NewThreadSheet(repo: repo)
            }
        }
        .sheet(isPresented: $showingAddRepoSheet) {
            AddRepoSheet()
        }
        .background {
            keyboardShortcuts
        }
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        // Cmd+T: new terminal tab
        Button("") {
            Task {
                await appState.startPreset(named: "terminal")
            }
        }
            .keyboardShortcut("t", modifiers: .command)
            .hidden()

        // Cmd+Shift+T: new thread
        Button("") { appState.openNewThreadSheet() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .hidden()

        // Cmd+W: close selected thread
        Button("") { appState.closeSelectedThread() }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()

        // Cmd+Shift+R: restart current preset
        Button("") { appState.restartCurrentPreset() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .hidden()

        // Cmd+K: toggle connection
        Button("") { appState.toggleConnection() }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .hidden()

    }
}
