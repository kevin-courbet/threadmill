import SwiftUI

struct ThreadRow: View {
    let thread: ThreadModel
    let isSelected: Bool
    let isPinned: Bool
    let onCancelCreation: (ThreadModel) -> Void
    let onTogglePin: (ThreadModel) -> Void
    @State private var isHovered = false

    init(
        thread: ThreadModel,
        isSelected: Bool = false,
        isPinned: Bool = false,
        onCancelCreation: @escaping (ThreadModel) -> Void = { _ in },
        onTogglePin: @escaping (ThreadModel) -> Void = { _ in }
    ) {
        self.thread = thread
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.onCancelCreation = onCancelCreation
        self.onTogglePin = onTogglePin
    }

    private var showBranch: Bool {
        thread.branch != thread.name
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Icon column — same 22pt width as project avatar for alignment
            ZStack {
                if isPinned || isHovered {
                    Button {
                        onTogglePin(thread)
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isPinned ? .secondary : .tertiary)
                            .rotationEffect(.degrees(45))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: showBranch ? 2 : 0) {
                Text(thread.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if showBranch {
                    Text(thread.branch)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                    ? Color.white.opacity(0.1)
                    : isHovered ? Color.white.opacity(0.05) : .clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered in isHovered = hovered }
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
