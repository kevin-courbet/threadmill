import SwiftUI

struct AutomationControlsView: View {
    @Environment(AppState.self) private var appState

    let thread: ThreadModel
    @Binding var selectedTab: String
    @Binding var terminalSessionIDs: [String]
    @Binding var selectedTerminalSessionID: String?
    let chatConversations: [ChatConversation]
    @Binding var selectedChatConversationID: String?
    let onAttachSelectedTerminalIfNeeded: () -> Void
    let onArchiveChatConversation: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(appState.debugSnapshot().summary)
                .accessibilityIdentifier("automation.app-debug")

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

            Button("Automation Switch Chat") {
                selectedTab = TabItem.chat.id
            }
            .accessibilityIdentifier("automation.switch-chat")
            .accessibilityLabel("Automation Switch Chat")

            ForEach(chatConversations) { conversation in
                Button("Automation Select Chat \(conversation.id)") {
                    selectedChatConversationID = conversation.id
                }
                .accessibilityIdentifier("automation.select-chat.\(conversation.id)")
                .accessibilityLabel("Automation Select Chat \(conversation.id)")

                Button("Automation Close Chat \(conversation.id)") {
                    onArchiveChatConversation(conversation.id)
                }
                .accessibilityIdentifier("automation.close-chat.\(conversation.id)")
                .accessibilityLabel("Automation Close Chat \(conversation.id)")
            }

            ForEach(appState.presets, id: \.name) { preset in
                Button("Automation Preset \(preset.name)") {
                    selectedTab = TabItem.terminal.id
                    if !terminalSessionIDs.contains(preset.name) {
                        terminalSessionIDs.append(preset.name)
                    }
                    selectedTerminalSessionID = preset.name
                    onAttachSelectedTerminalIfNeeded()
                }
                .accessibilityIdentifier("automation.select-preset.\(preset.name)")
                .accessibilityLabel("Automation Preset \(preset.name)")

                if let snapshot = appState.terminalDebugSnapshot(for: preset.name) {
                    Text(snapshot.summary)
                        .accessibilityIdentifier("automation.terminal-debug.\(preset.name)")
                }
            }
        }
        .font(.caption2)
    }
}
