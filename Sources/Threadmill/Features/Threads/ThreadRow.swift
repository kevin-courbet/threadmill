import SwiftUI

struct ThreadRow: View {
    let thread: ThreadModel
    let onCancelCreation: (ThreadModel) -> Void

    init(thread: ThreadModel, onCancelCreation: @escaping (ThreadModel) -> Void = { _ in }) {
        self.thread = thread
        self.onCancelCreation = onCancelCreation
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(status: thread.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.name)
                    .lineLimit(1)
                Text(thread.branch)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if thread.status == .creating {
                Button {
                    onCancelCreation(thread)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel thread creation")
                .accessibilityIdentifier("thread.cancel.\(thread.id)")
            }
        }
    }
}
