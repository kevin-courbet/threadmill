import SwiftUI

struct PermissionOptionButton: View {
    enum Style {
        case banner
        case inline
    }

    let option: (id: String, label: String)
    let kind: String
    let style: Style
    let action: () -> Void

    private enum VisualKind {
        case allowAlways
        case allow
        case deny
        case neutral
    }

    private var visualKind: VisualKind {
        let value = kind.lowercased()
        if value == "allow_always" { return .allowAlways }
        if value.contains("allow") { return .allow }
        if value.contains("reject") || value.contains("deny") { return .deny }
        return .neutral
    }

    private var foreground: Color {
        switch visualKind {
        case .allowAlways, .allow, .deny: .white
        case .neutral: ChatTokens.textPrimary
        }
    }

    private var background: AnyShapeStyle {
        switch visualKind {
        case .allowAlways:
            AnyShapeStyle(ChatTokens.statusSuccess)
        case .allow:
            AnyShapeStyle(ChatTokens.accentGradient)
        case .deny:
            AnyShapeStyle(ChatTokens.statusError)
        case .neutral:
            AnyShapeStyle(Color.clear)
        }
    }

    private var borderColor: Color {
        switch visualKind {
        case .allowAlways:
            ChatTokens.statusSuccess.opacity(0.35)
        case .allow:
            ChatTokens.borderAccent.opacity(0.4)
        case .deny:
            ChatTokens.statusError.opacity(0.4)
        case .neutral:
            ChatTokens.borderSubtle
        }
    }

    private var iconName: String? {
        switch visualKind {
        case .allowAlways, .allow:
            "checkmark.circle.fill"
        case .deny:
            "xmark.circle.fill"
        case .neutral:
            nil
        }
    }

    private var horizontalPadding: CGFloat {
        style == .banner ? 12 : 10
    }

    private var verticalPadding: CGFloat {
        style == .banner ? 7 : 5
    }

    private var fontSize: CGFloat {
        style == .banner ? ChatTokens.bodyFontSize : ChatTokens.captionFontSize
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: fontSize - 1, weight: .semibold))
                }

                Text(option.label)
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
