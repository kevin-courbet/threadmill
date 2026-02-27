import SwiftUI

func instantToggleTransaction() -> Transaction {
    var transaction = Transaction()
    transaction.animation = nil
    transaction.disablesAnimations = true
    return transaction
}

struct ProjectSection: View {
    let project: Project
    let threads: [ThreadModel]
    @Binding var selectedThreadID: String?
    let onNewThread: (Project) -> Void
    let onCancelThreadCreation: (ThreadModel) -> Void
    let onHideThread: (ThreadModel) -> Void
    let onCloseThread: (ThreadModel) -> Void
    let onReopenThread: (ThreadModel) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if isExpanded {
                mainBranchRow

                if threads.isEmpty {
                    Text("No threads yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 38)
                        .padding(.vertical, 3)
                } else {
                    ForEach(threads) { thread in
                        threadRow(thread)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("project.section.\(project.id)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(project.avatarColor.opacity(0.9))
                Text(project.avatarLetter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text("\(threads.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.06), in: Capsule())

            Spacer(minLength: 0)

            Button {
                onNewThread(project)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.section.new-thread.\(project.id)")

            Button {
                toggleExpanded()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.section.toggle.\(project.id)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func toggleExpanded() {
        withTransaction(instantToggleTransaction()) {
            isExpanded.toggle()
        }
    }

    private var mainBranchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(project.defaultBranch)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadModel) -> some View {
        let isSelected = selectedThreadID == thread.id

        ThreadRow(thread: thread, onCancelCreation: onCancelThreadCreation)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .padding(.leading, 24)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedThreadID = thread.id
            }
            .accessibilityIdentifier("thread.row.\(thread.id)")
            .background(isSelected ? Color.white.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contextMenu {
                if thread.status == .hidden {
                    Button("Reopen") {
                        onReopenThread(thread)
                    }
                } else {
                    Button("Hide") {
                        onHideThread(thread)
                    }
                    Button("Close", role: .destructive) {
                        onCloseThread(thread)
                    }
                }
            }
    }
}
