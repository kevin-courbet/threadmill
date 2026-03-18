import SwiftUI

struct TerminalModeContent: View {
    @Environment(AppState.self) private var appState

    let terminalSessionIDs: [String]
    let selectedTerminalSessionID: String?
    let isMockTerminalEnabled: Bool
    let onAddDefaultTerminalSession: () -> Void
    let onAddTerminalSession: (String) -> Void

    var body: some View {
        if terminalSessionIDs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text("No terminal sessions")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Button("New Terminal") {
                    onAddDefaultTerminalSession()
                }
                .buttonStyle(.borderedProminent)

                if appState.presets.count > 1 {
                    VStack(spacing: 4) {
                        Text("Or start a preset")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)

                        ForEach(appState.presets) { preset in
                            Button(preset.label) {
                                onAddTerminalSession(preset.name)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(terminalSessionIDs, id: \.self) { preset in
                    let isSelected = preset == selectedTerminalSessionID
                    terminalSessionView(for: preset)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func terminalSessionView(for preset: String) -> some View {
        if let endpoint = terminalEndpoints[preset] {
            if isMockTerminalEnabled {
                Text("Mock terminal: \(endpoint.preset)")
                    .accessibilityIdentifier("terminal.mock.text")
            } else {
                GhosttyTerminalView(endpoint: endpoint)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(appState.connectionStatus == .disconnected ? "Disconnected" : "Starting terminal...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let snapshot = appState.terminalDebugSnapshot(for: preset) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.summary)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 360, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("terminal.debug.summary.\(preset)")
                        Text(debugJSONString(snapshot))
                            .accessibilityIdentifier("terminal.debug.json.\(preset)")
                    }
                }
            }
            .accessibilityIdentifier("terminal.connecting")
        }
    }

    private var terminalEndpoints: [String: RelayEndpoint] {
        TerminalModeActions.terminalEndpoints(appState: appState)
    }
}

@MainActor
enum TerminalModeActions {
    static func terminalEndpoints(appState: AppState) -> [String: RelayEndpoint] {
        Dictionary(uniqueKeysWithValues: appState.terminalTabs.compactMap { tab in
            guard let presetName = tab.preset?.name, let endpoint = tab.endpoint else {
                return nil
            }
            return (presetName, endpoint)
        })
    }

    static func defaultTerminalPresetName(appState: AppState) -> String? {
        let openPresets = Set(appState.terminalTabs.compactMap(\.preset?.name))

        if let terminalPreset = appState.presets.first(where: { $0.name == "terminal" && !openPresets.contains($0.name) }) {
            return terminalPreset.name
        }

        if let unopenedPreset = appState.presets.first(where: { !openPresets.contains($0.name) }) {
            return unopenedPreset.name
        }

        return nil
    }

    static func addDefaultTerminalSession(
        appState: AppState,
        terminalSessionIDs: Binding<[String]>,
        selectedTerminalSessionIDBinding: Binding<String?>,
        tabStateManager: ThreadTabStateManager
    ) {
        guard let preset = defaultTerminalPresetName(appState: appState) else {
            return
        }
        addTerminalSession(
            preset: preset,
            appState: appState,
            terminalSessionIDs: terminalSessionIDs,
            selectedTerminalSessionIDBinding: selectedTerminalSessionIDBinding,
            tabStateManager: tabStateManager
        )
    }

    static func addTerminalSession(
        preset: String,
        appState: AppState,
        terminalSessionIDs: Binding<[String]>,
        selectedTerminalSessionIDBinding: Binding<String?>,
        tabStateManager: ThreadTabStateManager
    ) {
        guard appState.presets.contains(where: { $0.name == preset }) else {
            return
        }

        if !terminalSessionIDs.wrappedValue.contains(preset) {
            terminalSessionIDs.wrappedValue.append(preset)
        }
        selectedTerminalSessionIDBinding.wrappedValue = preset

        guard let thread = appState.selectedThread else {
            return
        }
        let threadID = thread.id
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs.wrappedValue, threadID: threadID)

        Task {
            await appState.startPreset(threadID: threadID, preset: preset)
            await MainActor.run {
                attachSelectedTerminalIfNeeded(
                    appState: appState,
                    selectedTerminalSessionID: selectedTerminalSessionIDBinding.wrappedValue,
                    threadID: threadID
                )
            }
        }
    }

    static func closeTerminalSessions(
        _ sessionIDs: [String],
        appState: AppState,
        terminalSessionIDs: Binding<[String]>,
        selectedTerminalSessionIDBinding: Binding<String?>,
        isTerminalModeSelected: @escaping () -> Bool,
        tabStateManager: ThreadTabStateManager
    ) {
        guard !sessionIDs.isEmpty else {
            return
        }

        let idsToClose = Set(sessionIDs)
        terminalSessionIDs.wrappedValue.removeAll { idsToClose.contains($0) }
        if let selectedTerminalSessionID = selectedTerminalSessionIDBinding.wrappedValue,
           idsToClose.contains(selectedTerminalSessionID)
        {
            selectedTerminalSessionIDBinding.wrappedValue = terminalSessionIDs.wrappedValue.first
        }

        guard let thread = appState.selectedThread else {
            return
        }
        let threadID = thread.id
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs.wrappedValue, threadID: threadID)

        Task {
            for sessionID in sessionIDs {
                await appState.stopPreset(threadID: threadID, preset: sessionID)
            }
            await MainActor.run {
                if isTerminalModeSelected() {
                    attachSelectedTerminalIfNeeded(
                        appState: appState,
                        selectedTerminalSessionID: selectedTerminalSessionIDBinding.wrappedValue,
                        threadID: threadID
                    )
                }
            }
        }
    }

    static func attachSelectedTerminalIfNeeded(
        appState: AppState,
        selectedTerminalSessionID: String?,
        threadID: String? = nil
    ) {
        guard let selectedTerminalSessionID else {
            return
        }

        guard let threadID = threadID ?? appState.selectedThreadID else {
            return
        }

        Task {
            await appState.attachPreset(threadID: threadID, preset: selectedTerminalSessionID)
        }
    }
}
