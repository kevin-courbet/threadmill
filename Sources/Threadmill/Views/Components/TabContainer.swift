import SwiftUI

enum TabContainerStyle {
    case capsule
    case topBorder
}

struct TabContainer<Content: View>: View {
    let isSelected: Bool
    let style: TabContainerStyle
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        isSelected: Bool,
        style: TabContainerStyle = .capsule,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isSelected = isSelected
        self.style = style
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            switch style {
            case .capsule:
                content()
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.1) : .clear)
                    )
            case .topBorder:
                content()
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(isSelected ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}
