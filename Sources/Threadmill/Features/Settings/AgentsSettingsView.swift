import os
import SwiftUI

struct AgentsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var installingAgentID: String?
    @State private var installError: String?

    var body: some View {
        Form {
            Section {
                if appState.agentRegistry.isEmpty {
                    Text("No remote connected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.agentRegistry) { agent in
                        AgentRow(
                            agent: agent,
                            isInstalling: installingAgentID == agent.id,
                            onInstall: { installAgent(agent) }
                        )
                    }
                }
            } header: {
                Text("Available Agents")
            } footer: {
                Text("Agents are installed on the remote machine. Only installed agents appear in the Chat tab.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Install Failed", isPresented: .init(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK") { installError = nil }
        } message: {
            if let installError {
                Text(installError)
            }
        }
    }

    private func installAgent(_ agent: AgentRegistryEntry) {
        installingAgentID = agent.id
        installError = nil
        Task {
            defer { installingAgentID = nil }
            do {
                let success = try await appState.installAgent(agentID: agent.id)
                if !success {
                    installError = "Installation of \(agent.name) did not complete successfully."
                }
            } catch {
                installError = error.localizedDescription
            }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentRegistryEntry
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(agent.installed ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    Text(agent.command)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let path = agent.resolvedPath {
                        Text("(\(path))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            if agent.installed {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if agent.installMethod != nil {
                Button("Install") {
                    onInstall()
                }
                .controlSize(.small)
            } else {
                Text("Not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
