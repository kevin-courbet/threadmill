import SwiftUI

/// Small icon button that brightens on hover.
struct HoverButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovered = false

    init(systemName: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
