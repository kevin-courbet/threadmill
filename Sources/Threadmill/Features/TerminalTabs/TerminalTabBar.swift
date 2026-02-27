import SwiftUI

struct TerminalTabBar: View {
    let tabs: [TerminalTabModel]
    let availablePresets: [Preset]
    @Binding var selectedPreset: String?
    let onClose: (String) -> Void
    let onAdd: (String) -> Void

    @State private var hoveredPresetName: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }

            addPresetButton

            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityIdentifier("terminal.tab-bar")
    }

    @ViewBuilder
    private func tabButton(for tab: TerminalTabModel) -> some View {
        let isSelected = selectedPreset == tab.preset.name
        let showsClose = isSelected || hoveredPresetName == tab.preset.name

        HStack(spacing: 8) {
            Button {
                selectedPreset = tab.preset.name
            } label: {
                HStack(spacing: 6) {
                    Text(tab.preset.label)
                        .font(.subheadline)
                        .lineLimit(1)

                    Circle()
                        .fill(tab.isAttached ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                }
                .frame(height: 34)
                .padding(.leading, 12)
                .padding(.trailing, showsClose ? 0 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsClose {
                Button {
                    onClose(tab.preset.name)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Stop \(tab.preset.label)")
            }
        }
        .background(isSelected ? Color.white.opacity(0.08) : .clear)
        .overlay(alignment: .trailing) {
            if tab.id != tabs.last?.id {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }
        }
        .onHover { hovering in
            hoveredPresetName = hovering ? tab.preset.name : nil
        }
        .accessibilityIdentifier("terminal.tab.\(tab.preset.name)")
    }

    private var addPresetButton: some View {
        Menu {
            if availablePresets.isEmpty {
                Text("No presets available")
            } else {
                ForEach(availablePresets) { preset in
                    Button(preset.label) {
                        onAdd(preset.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(width: 44, height: 34)
            .foregroundStyle(.secondary)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .padding(.leading, 6)
        }
        .buttonStyle(.plain)
        .disabled(availablePresets.isEmpty)
        .accessibilityIdentifier("terminal.tab.add")
    }
}
