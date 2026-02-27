import SwiftUI

struct ThreadRow: View {
    let thread: ThreadModel
    let onCancelCreation: (ThreadModel) -> Void

    init(thread: ThreadModel, onCancelCreation: @escaping (ThreadModel) -> Void = { _ in }) {
        self.thread = thread
        self.onCancelCreation = onCancelCreation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(thread.branch)
                    .font(.caption2)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
