import SwiftUI

private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

enum SettingsSection: Hashable {
    case general
    case remotes
    case agents
    case chat
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    let databaseManager: (any DatabaseManaging)?
    let gitHubAuthManager: GitHubAuthManager

    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label("General", systemImage: "gear")
                    .tag(SettingsSection.general)
                Label("Remotes", systemImage: "server.rack")
                    .tag(SettingsSection.remotes)
                Label("Agents", systemImage: "cpu")
                    .tag(SettingsSection.agents)
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag(SettingsSection.chat)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, maxWidth: 200, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(200)
            .removingSidebarToggle()
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView()
                .navigationTitle("General")
        case .remotes:
            RemotesSettingsView(databaseManager: databaseManager, appState: appState)
                .navigationTitle("Remotes")
        case .agents:
            AgentsSettingsView()
                .navigationTitle("Agents")
        case .chat:
            ChatSettingsView(gitHubAuthManager: gitHubAuthManager)
                .navigationTitle("Chat")
        case .none:
            GeneralSettingsView()
                .navigationTitle("General")
        }
    }
}
