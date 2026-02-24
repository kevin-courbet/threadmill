import SwiftUI

struct TerminalTabBar: View {
    let tabs: [TerminalTabModel]
    @Binding var selectedPreset: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                Button {
                    selectedPreset = tab.preset.name
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.preset.label)
                            .font(.caption.weight(.medium))
                        Circle()
                            .fill(tab.isAttached ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(selectedPreset == tab.preset.name ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.tab.\(tab.preset.name)")
            }
        }
        .accessibilityIdentifier("terminal.tab-bar")
    }
}
