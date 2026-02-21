import SwiftUI

struct ThreadDetailView: View {
    @Environment(AppState.self) private var appState

    private var projectName: String {
        guard let thread = appState.selectedThread else {
            return ""
        }
        return appState.projects.first(where: { $0.id == thread.projectId })?.name ?? "Unknown Project"
    }

    var body: some View {
        @Bindable var bindableState = appState

        if let thread = appState.selectedThread {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.name)
                        .font(.title2.weight(.semibold))
                    Text("\(projectName) · \(thread.branch)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TerminalTabBar(
                    presets: appState.presets,
                    threadStatus: thread.status,
                    selectedPreset: $bindableState.selectedPreset
                )

                TerminalTabView(endpoint: appState.selectedEndpoint)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(16)
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
