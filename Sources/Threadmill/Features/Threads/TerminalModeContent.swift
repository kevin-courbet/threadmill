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
            }
            .accessibilityIdentifier("terminal.connecting")
        }
    }

    private var terminalEndpoints: [String: RelayEndpoint] {
        TerminalModeActions.terminalEndpoints(appState: appState, sessionIDs: terminalSessionIDs)
    }
}

@MainActor
enum TerminalModeActions {
    static func defaultTerminalPresetName(appState: AppState) -> String? {
        appState.presets.contains(where: { $0.name == "terminal" }) ? "terminal" : nil
    }

    /// Map session IDs to their attached endpoints.
    /// Session IDs like "terminal-1" map to the endpoint keyed by that session ID in AppState.
    static func terminalEndpoints(appState: AppState, sessionIDs: [String]) -> [String: RelayEndpoint] {
        guard let thread = appState.selectedThread else {
            return [:]
        }
        var result: [String: RelayEndpoint] = [:]
        for sessionID in sessionIDs {
            if let endpoint = appState.endpointForSession(threadID: thread.id, sessionID: sessionID) {
                result[sessionID] = endpoint
            }
        }
        return result
    }

    /// The + button always creates a new terminal instance.
    /// Terminal sessions get unique IDs like terminal-1, terminal-2.
    /// The daemon preset name is always "terminal".
    static func addDefaultTerminalSession(
        appState: AppState,
        terminalSessionIDs: Binding<[String]>,
        selectedTerminalSessionIDBinding: Binding<String?>,
        tabStateManager: ThreadTabStateManager
    ) {
        guard defaultTerminalPresetName(appState: appState) != nil else {
            return
        }
        guard let thread = appState.selectedThread else {
            return
        }

        let existingTerminalCount = terminalSessionIDs.wrappedValue.filter { presetName(forSessionID: $0) == "terminal" }.count
        let sessionID = "terminal-\(existingTerminalCount + 1)"

        terminalSessionIDs.wrappedValue.append(sessionID)
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs.wrappedValue, threadID: thread.id)
        selectedTerminalSessionIDBinding.wrappedValue = sessionID
        tabStateManager.setSelectedSessionID(sessionID, modeID: TabItem.terminal.id, threadID: thread.id)
    }

    /// Named presets (dev-server, etc.) are one-instance-only.
    /// If already open, just select it.
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
        guard let thread = appState.selectedThread else {
            return
        }
        let threadID = thread.id

        // Named presets use their name directly as session ID (one instance only)
        if terminalSessionIDs.wrappedValue.contains(preset) {
            selectedTerminalSessionIDBinding.wrappedValue = preset
            tabStateManager.setSelectedSessionID(preset, modeID: TabItem.terminal.id, threadID: threadID)
            return
        }

        terminalSessionIDs.wrappedValue.append(preset)
        tabStateManager.setTerminalSessionIDs(terminalSessionIDs.wrappedValue, threadID: threadID)
        selectedTerminalSessionIDBinding.wrappedValue = preset
        tabStateManager.setSelectedSessionID(preset, modeID: TabItem.terminal.id, threadID: threadID)
    }

    /// Extract the daemon preset name from a session ID.
    /// "terminal-1" → "terminal", "dev-server" → "dev-server"
    static func presetName(forSessionID sessionID: String) -> String {
        if sessionID.hasPrefix("terminal-"), sessionID.dropFirst("terminal-".count).allSatisfy(\.isNumber) {
            return "terminal"
        }
        return sessionID
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
