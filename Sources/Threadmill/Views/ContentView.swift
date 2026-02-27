import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddProjectSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showingAddProjectSheet: $showingAddProjectSheet)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
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
        .sheet(isPresented: Bindable(appState).isNewThreadSheetPresented) {
            NewThreadSheet()
        }
        .sheet(isPresented: $showingAddProjectSheet) {
            AddProjectSheet()
        }
        .background {
            keyboardShortcuts
        }
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        // Cmd+T: new thread
        Button("") { appState.openNewThreadSheet() }
            .keyboardShortcut("t", modifiers: .command)
            .hidden()

        // Cmd+W: close selected thread
        Button("") { appState.closeSelectedThread() }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()

        // Ctrl+Tab / Ctrl+Shift+Tab: cycle preset tabs
        Button("") { appState.nextPresetTab() }
            .keyboardShortcut("]", modifiers: .command)
            .hidden()
        Button("") { appState.previousPresetTab() }
            .keyboardShortcut("[", modifiers: .command)
            .hidden()

        // Cmd+Shift+R: restart current preset
        Button("") { appState.restartCurrentPreset() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .hidden()

        // Cmd+K: toggle connection
        Button("") { appState.toggleConnection() }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .hidden()

        // Cmd+1 through Cmd+9: select thread by index
        ForEach(1...9, id: \.self) { index in
            Button("") { appState.selectThreadByIndex(index - 1) }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .hidden()
        }
    }
}
