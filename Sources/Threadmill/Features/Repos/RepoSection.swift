import SwiftUI

struct RepoSection: View {
    let repo: Repo
    let threads: [ThreadModel]
    let canCreateThread: Bool
    @Binding var selectedThreadID: String?
    let onNewThread: (Repo) -> Void
    let onCancelThreadCreation: (ThreadModel) -> Void
    let onHideThread: (ThreadModel) -> Void
    let onCloseThread: (ThreadModel) -> Void
    let onReopenThread: (ThreadModel) -> Void

    @State private var isExpanded = true
    @State private var isHeaderHovered = false

    var body: some View {
        Section(isExpanded: $isExpanded) {
            if displayedThreads.isEmpty {
                Text("No threads yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
                    .padding(.vertical, 3)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(displayedThreads) { thread in
                    threadRow(thread)
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            header
        }
        .listSectionSeparator(.hidden, edges: .all)
        .accessibilityIdentifier("repo.section.\(repo.id)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(repo.avatarColor.opacity(0.9))
                Text(repo.avatarLetter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !repo.owner.isEmpty {
                    Text(repo.owner)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                onNewThread(repo)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .disabled(!canCreateThread)
            .buttonStyle(.plain)
            .accessibilityIdentifier("repo.section.new-thread.\(repo.id)")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHeaderHovered ? Color.white.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered in
            isHeaderHovered = isHovered
        }
        .accessibilityIdentifier("repo.section.toggle.\(repo.id)")
    }

    private var displayedThreads: [ThreadModel] {
        threads.sorted { $0.createdAt > $1.createdAt }
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
