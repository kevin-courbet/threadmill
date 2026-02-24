import SwiftUI

struct TerminalTabBar: View {
    let tabs: [TerminalTabModel]
    let threadStatus: ThreadStatus
    @Binding var selectedPreset: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                Button {
                    selectedPreset = tab.preset.name
                } label: {
                    HStack(spacing: 6) {
                        StatusIndicator(status: threadStatus)
                        Text(tab.preset.label)
                        Circle()
                            .fill(tab.isAttached ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedPreset == tab.preset.name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
