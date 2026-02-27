import SwiftUI

struct ThreadDetailView: View {
    @Environment(AppState.self) private var appState

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1"
    }

    private var projectName: String {
        guard let thread = appState.selectedThread else {
            return ""
        }
        return appState.projects.first(where: { $0.id == thread.projectId })?.name ?? "Unknown Project"
    }

    var body: some View {
        @Bindable var bindableState = appState

        if let thread = appState.selectedThread {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("\(projectName) · \(thread.name)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    TerminalTabBar(
                        tabs: appState.terminalTabs,
                        selectedPreset: $bindableState.selectedPreset
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if thread.status == .active {
                    TerminalTabView(
                        endpoint: appState.selectedEndpoint,
                        isConnecting: appState.connectionStatus != .disconnected
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: thread.status == .creating ? "hourglass" : "terminal")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(thread.status == .creating ? "Creating thread..." : "Thread is \(thread.status.rawValue)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if thread.status == .closed || thread.status == .hidden {
                            Button("Reopen") {
                                Task { await appState.reopenThread(threadID: thread.id) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isUITestMode {
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
                                bindableState.selectedThreadID = candidate.id
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
                                bindableState.selectedPreset = preset.name
                            }
                            .accessibilityIdentifier("automation.select-preset.\(preset.name)")
                            .accessibilityLabel("Automation Preset \(preset.name)")
                        }
                    }
                    .font(.caption2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
}
