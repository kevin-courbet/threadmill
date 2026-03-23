import AppKit
import SwiftUI

/// Emits flat rows into the parent List — no Section, no DisclosureGroup.
/// List natively animates ForEach row insertion/removal.
struct RepoSection: View {
    let repo: Repo
    let linkedProject: Project?
    let threads: [ThreadModel]
    let pinnedThreadIDs: Set<String>
    let canCreateThread: Bool
    @Binding var selectedThreadID: String?
    let onNewThread: (Repo) -> Void
    let onCancelThreadCreation: (ThreadModel) -> Void
    let onHideThread: (ThreadModel) -> Void
    let onCloseThread: (ThreadModel) -> Void
    let onReopenThread: (ThreadModel) -> Void
    let onRemoveProject: (Project) -> Void
    let onTogglePin: (ThreadModel) -> Void

    @State private var isExpanded = true
    @State private var isHeaderHovered = false
    @State private var threadPendingClose: ThreadModel?
    @State private var projectPendingRemoval: Project?

    var body: some View {
        Group {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                .listRowBackground(Color.clear)

            if isExpanded {
                if displayedThreads.isEmpty {
                    Text("No threads yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                        .padding(.leading, 30)
                        .padding(.vertical, 3)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 3, trailing: 10))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedThreads) { thread in
                        threadRow(thread)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .listRowBackground(Color.clear)
                            .tag(thread.id)
                            .accessibilityIdentifier("thread.row.\(thread.id)")
                            .accessibilityLabel("Open thread \(thread.name)")
                            .accessibilityValue(thread.branch)
                    }
                }
            }
        }
        .alert(
            "Close Thread?",
            isPresented: Binding(
                get: { threadPendingClose != nil },
                set: { isPresented in
                    if !isPresented {
                        threadPendingClose = nil
                    }
                }
            ),
            presenting: threadPendingClose
        ) { thread in
            Button("Cancel", role: .cancel) {
                threadPendingClose = nil
            }
            Button("Close Thread", role: .destructive) {
                onCloseThread(thread)
                threadPendingClose = nil
            }
        } message: { thread in
            Text("Close \(thread.name)? This will stop the tmux session and close its worktree.")
        }
        .alert(
            "Remove Repository?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingRemoval = nil
                    }
                }
            ),
            presenting: projectPendingRemoval
        ) { project in
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
            Button("Remove Repository", role: .destructive) {
                onRemoveProject(project)
                projectPendingRemoval = nil
            }
        } message: { project in
            Text("Remove \(repo.fullName) at \(project.remotePath)?")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isHeaderHovered
                ? (isExpanded ? "chevron.down" : "chevron.right")
                : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !repo.owner.isEmpty {
                    Text(repo.owner)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isHeaderHovered {
                HoverButton(systemName: "plus") {
                    onNewThread(repo)
                }
                .disabled(!canCreateThread)
                .transition(.opacity)
                .accessibilityIdentifier("repo.section.new-thread.\(repo.id)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isHeaderHovered ? Color.white.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered in
            isHeaderHovered = isHovered
        }
        .contextMenu {
            Button("New Thread") {
                onNewThread(repo)
            }

            Button("Copy Repository Name") {
                copyToPasteboard(repo.fullName)
            }

            if let linkedProject {
                Button("Copy Path") {
                    copyToPasteboard(linkedProject.remotePath)
                }

                Divider()

                Button("Remove Repository", role: .destructive) {
                    projectPendingRemoval = linkedProject
                }
            }
        }
    }

    private var displayedThreads: [ThreadModel] {
        threads.sorted { $0.createdAt > $1.createdAt }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadModel) -> some View {
        let isPinned = pinnedThreadIDs.contains(thread.id)

        ThreadRow(
            thread: thread,
            isSelected: selectedThreadID == thread.id,
            isPinned: isPinned,
            onCancelCreation: onCancelThreadCreation,
            onTogglePin: onTogglePin
        )
        .onTapGesture {
            selectedThreadID = thread.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.row.\(thread.id)")
        .contextMenu {
            Button(isPinned ? "Unpin Thread" : "Pin Thread") {
                onTogglePin(thread)
            }

            Divider()

            if thread.status == .hidden {
                Button("Reopen") {
                    onReopenThread(thread)
                }
            } else {
                Button("Hide Thread") {
                    onHideThread(thread)
                }
            }

            Button("Copy Branch Name") {
                copyToPasteboard(thread.branch)
            }

            Button("Copy Worktree Path") {
                copyToPasteboard(thread.worktreePath)
            }

            Button("Close Thread", role: .destructive) {
                threadPendingClose = thread
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
