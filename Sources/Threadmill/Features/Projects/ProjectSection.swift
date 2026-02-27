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
        .transaction { transaction in
            let instantTransaction = instantToggleTransaction()
            transaction.animation = instantTransaction.animation
            transaction.disablesAnimations = instantTransaction.disablesAnimations
        }
        .accessibilityIdentifier("project.section.\(project.id)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(project.avatarColor.opacity(0.9))
                Text(project.avatarLetter)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text("\(project.name) (\(threads.count))")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                onNewThread(project)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.section.new-thread.\(project.id)")

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpanded()
        }
    }

    private func toggleExpanded() {
        withTransaction(instantToggleTransaction()) {
            isExpanded.toggle()
        }
    }

    private var mainBranchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(project.defaultBranch)
                .font(.subheadline)
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
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .padding(.leading, 24)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedThreadID = thread.id
            }
            .accessibilityIdentifier("thread.row.\(thread.id)")
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
