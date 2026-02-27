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

            if !availablePresets.isEmpty {
                addPresetButton
            }

            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("terminal.tab-bar")
    }

    @ViewBuilder
    private func tabButton(for tab: TerminalTabModel) -> some View {
        let isSelected = selectedPreset == tab.preset.name
        let showsClose = isSelected || hoveredPresetName == tab.preset.name

        HStack(spacing: 4) {
            Button {
                selectedPreset = tab.preset.name
            } label: {
                Text(tab.preset.label)
                    .font(.subheadline)
                    .lineLimit(1)
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
        .onHover { hovering in
            hoveredPresetName = hovering ? tab.preset.name : nil
        }
        .accessibilityIdentifier("terminal.tab.\(tab.preset.name)")
    }

    private var addPresetButton: some View {
        Button {
            if let first = availablePresets.first {
                onAdd(first.name)
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(availablePresets.first.map { "Start \($0.label)" } ?? "")
        .accessibilityIdentifier("terminal.tab.add")
    }
}
