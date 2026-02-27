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
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(thread.branch)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let statusLabel {
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

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

    private var statusLabel: String? {
        switch thread.status {
        case .active:
            return nil
        case .creating:
            return "Starting"
        case .closing:
            return "Closing"
        case .hidden:
            return "Hidden"
        case .closed:
            return "Closed"
        case .failed:
            return "Failed"
        }
    }
}
