import SwiftUI

struct TabContainer<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}
