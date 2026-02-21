import SwiftUI

struct StatusIndicator: View {
    let status: ThreadStatus

    private var symbol: String {
        switch status {
        case .active:
            return "●"
        case .hidden, .closed:
            return "○"
        case .failed:
            return "✕"
        case .creating, .closing:
            return "⟳"
        }
    }

    private var color: Color {
        switch status {
        case .active:
            return .green
        case .hidden, .closed:
            return .secondary
        case .failed:
            return .red
        case .creating, .closing:
            return .orange
        }
    }

    var body: some View {
        Text(symbol)
            .foregroundStyle(color)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(width: 14)
    }
}
