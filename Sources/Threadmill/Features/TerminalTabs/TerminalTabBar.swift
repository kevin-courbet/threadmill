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
        .accessibilityIdentifier("terminal.tab-bar")
    }

    @ViewBuilder
    private func tabButton(for tab: TerminalTabModel) -> some View {
        let isSelected = selectedPreset == tab.selectionID
        let isCloseButtonVisible = tab.isClosable && (isSelected || hoveredPresetName == tab.selectionID)

        HStack(spacing: 6) {
            Button {
                selectedPreset = tab.selectionID
            } label: {
                Text(tab.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)

            Button {
                onClose(tab.selectionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(isCloseButtonVisible ? 1 : 0)
            .allowsHitTesting(isCloseButtonVisible)
            .accessibilityHidden(!tab.isClosable)
            .padding(.trailing, 10)
            .help(closeButtonHelpText(for: tab))
        }
        .frame(minWidth: 120, minHeight: 34, maxHeight: 34, alignment: .leading)
        .background(isSelected ? Color.white.opacity(0.08) : .clear)
        .onHover { hovering in
            hoveredPresetName = hovering ? tab.selectionID : nil
        }
        .accessibilityIdentifier("terminal.tab.\(tab.selectionID)")
    }

    private func closeButtonHelpText(for tab: TerminalTabModel) -> String {
        if tab.selectionID == TerminalTabModel.chatTabSelectionID {
            return "Close Chat"
        }
        return "Stop \(tab.title)"
    }

    private var addPresetButton: some View {
        Menu {
            ForEach(availablePresets) { preset in
                Button(preset.label) {
                    onAdd(preset.name)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
        } primaryAction: {
            onAdd("terminal")
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
        .help("Start Terminal (click) or choose preset (hold)")
        .accessibilityIdentifier("terminal.tab.add")
    }
}
