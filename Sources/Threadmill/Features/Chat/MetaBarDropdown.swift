import SwiftUI

/// Pill-shaped dropdown matching CodexMonitor's `.composer-select-wrap` pattern.
/// Renders as a compact capsule with icon + label + chevron caret.
/// Hover: background brightens, border lifts, slight translateY, icon tints accent.
struct MetaBarDropdown<ID: Hashable>: View {
    let icon: String
    let label: String
    let options: [(id: ID, name: String)]
    let selection: ID?
    let disabled: Bool
    let onSelect: (ID) -> Void

    @State private var isHovering = false

    init(
        icon: String,
        label: String,
        options: [(id: ID, name: String)],
        selection: ID?,
        disabled: Bool = false,
        onSelect: @escaping (ID) -> Void
    ) {
        self.icon = icon
        self.label = label
        self.options = options
        self.selection = selection
        self.disabled = disabled
        self.onSelect = onSelect
    }

    private var displayLabel: String {
        if let selection, let match = options.first(where: { $0.id == selection }) {
            return match.name
        }
        return label
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    HStack {
                        Text(option.name)
                        if option.id == selection {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHovering ? ChatTokens.textPrimary : ChatTokens.textSubtle)

                Text(displayLabel)
                    .font(.system(size: ChatTokens.metaFontSize, weight: .medium))
                    .foregroundStyle(
                        disabled
                            ? ChatTokens.textFaint
                            : (isHovering ? ChatTokens.textPrimary : ChatTokens.textMuted)
                    )
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isHovering ? ChatTokens.textMuted : ChatTokens.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? ChatTokens.surfaceCardStrong : ChatTokens.surfaceCard)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isHovering ? ChatTokens.borderHeavy : ChatTokens.borderSubtle,
                        lineWidth: isHovering ? 1 : 0.5
                    )
            )
            .shadow(
                color: isHovering ? .black.opacity(0.18) : .clear,
                radius: isHovering ? 6 : 0,
                y: isHovering ? 2 : 0
            )
            .offset(y: isHovering ? -0.5 : 0)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(disabled || options.isEmpty)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: ChatTokens.durFast), value: isHovering)
    }
}
