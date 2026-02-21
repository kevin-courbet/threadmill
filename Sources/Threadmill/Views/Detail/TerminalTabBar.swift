import SwiftUI

struct TerminalTabBar: View {
    let presets: [Preset]
    let threadStatus: ThreadStatus
    @Binding var selectedPreset: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets) { preset in
                Button {
                    selectedPreset = preset.name
                } label: {
                    HStack(spacing: 6) {
                        StatusIndicator(status: threadStatus)
                        Text(preset.label)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedPreset == preset.name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
