import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(GitHubAuthManager.self) private var gitHubAuthManager
    @State private var showingAddRepoSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingAddRepoSheet: $showingAddRepoSheet)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            if appState.repos.isEmpty && appState.projects.isEmpty {
                defaultWorkspaceEmptyState
            } else if appState.selectedThread != nil {
                ThreadDetailView()
            } else {
                defaultWorkspaceEmptyState
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Bindable(appState).isNewThreadSheetPresented) {
            if let repo = appState.defaultWorkspaceRepo ?? appState.repos.first {
                NewThreadSheet(repo: repo)
            }
        }
        .sheet(isPresented: $showingAddRepoSheet) {
            AddRepoSheet(authManager: gitHubAuthManager)
        }
        .alert(
            "Unable to Open New Thread",
            isPresented: Binding(
                get: { appState.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.alertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage ?? "")
        }
        .background { keyboardShortcuts }
    }

    @ViewBuilder
    private var defaultWorkspaceEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)

            Text("Where do you want to run this?")
                .font(.title3.weight(.semibold))

            if appState.remotes.isEmpty {
                Text("Configure a remote in Settings to start using Cross-project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Remote", selection: Bindable(appState).selectedWorkspaceRemoteID) {
                    ForEach(appState.remotes) { remote in
                        Text(remote.name).tag(Optional(remote.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("default-workspace.remote-picker")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
