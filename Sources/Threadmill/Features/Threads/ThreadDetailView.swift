import SwiftUI

struct ThreadDetailView: View {
    @Environment(AppState.self) private var appState

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1"
    }

    var body: some View {
        @Bindable var bindableState = appState

        if let thread = appState.selectedThread {
            VStack(spacing: 0) {
                TerminalTabBar(
                    tabs: appState.terminalTabs,
                    availablePresets: appState.startablePresets,
                    selectedPreset: $bindableState.selectedPreset,
                    onClose: { preset in
                        Task {
                            await appState.stopPreset(named: preset)
                        }
                    },
                    onAdd: { preset in
                        Task {
                            await appState.startPreset(named: preset)
                        }
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if thread.status == .active {
                    if appState.selectedPreset == TerminalTabModel.chatTabSelectionID {
                        if let openCodeClient = appState.openCodeClient {
                            ChatView(directory: thread.worktreePath, openCodeClient: openCodeClient)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView(
                                "Chat unavailable",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("OpenCode client is not configured.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        TerminalTabView(
                            endpoint: appState.selectedEndpoint,
                            isConnecting: appState.connectionStatus != .disconnected
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: thread.status == .creating ? "hourglass" : "terminal")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(thread.status == .creating ? "Creating thread..." : "Thread is \(thread.status.rawValue)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if thread.status == .hidden {
                            Button("Reopen") {
                                Task { await appState.reopenThread(threadID: thread.id) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if isUITestMode {
                    automationControls(thread: thread)
                        .padding(8)
                }
            }
            .onAppear {
                if appState.selectedPreset == nil {
                    appState.selectedPreset = appState.presets.first?.name
                }
                Task {
                    await appState.attachSelectedPreset()
                }
            }
            .onChange(of: appState.selectedPreset) { _, _ in
                Task {
                    await appState.attachSelectedPreset()
                }
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func automationControls(thread: ThreadModel) -> some View {
        VStack(spacing: 2) {
            Button("Automation Open Add Project") {
                Task {
                    try? await appState.addProject(path: "/home/wsl/dev/factorio")
                }
            }
            .accessibilityIdentifier("automation.open-add-project")
            .accessibilityLabel("Automation Open Add Project")

            Button("Automation Open New Thread") {
                Task {
                    guard let projectID = appState.projects.first?.id else {
                        return
                    }
                    try? await appState.createThread(
                        projectID: projectID,
                        name: "ui-e2e-thread",
                        sourceType: "new_feature",
                        branch: nil
                    )
                }
            }
            .accessibilityIdentifier("automation.open-new-thread")
            .accessibilityLabel("Automation Open New Thread")

            ForEach(appState.threads) { candidate in
                Button("Automation Switch \(candidate.id)") {
                    appState.selectedThreadID = candidate.id
                }
                .accessibilityIdentifier("automation.switch-thread.\(candidate.id)")
                .accessibilityLabel("Automation Switch \(candidate.id)")
            }

            Button("Automation Close Selected") {
                Task {
                    await appState.closeThread(threadID: thread.id)
                }
            }
            .accessibilityIdentifier("automation.close-selected-thread")
            .accessibilityLabel("Automation Close Selected")

            ForEach(appState.presets, id: \.name) { preset in
                Button("Automation Preset \(preset.name)") {
                    appState.selectedPreset = preset.name
                }
                .accessibilityIdentifier("automation.select-preset.\(preset.name)")
                .accessibilityLabel("Automation Preset \(preset.name)")
            }
        }
        .font(.caption2)
    }
}
