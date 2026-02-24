import SwiftUI

struct ThreadRow: View {
    let thread: ThreadModel

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(status: thread.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.name)
                    .lineLimit(1)
                Text(thread.branch)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
