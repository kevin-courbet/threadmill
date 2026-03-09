import AppKit
import SwiftUI

/// Emits flat rows into the parent List — no Section, no DisclosureGroup.
/// List natively animates ForEach row insertion/removal.
struct ProjectSection: View {
    let project: Project
    let threads: [ThreadModel]
    let canCreateThread: Bool
    @Binding var selectedThreadID: String?
    let onNewThread: (Project) -> Void
    let onCancelThreadCreation: (ThreadModel) -> Void
    let onHideThread: (ThreadModel) -> Void
    let onCloseThread: (ThreadModel) -> Void
    let onReopenThread: (ThreadModel) -> Void
    let onRemoveProject: (Project) -> Void

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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 48)
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
        ) { pendingProject in
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
            Button("Remove Repository", role: .destructive) {
                onRemoveProject(pendingProject)
                projectPendingRemoval = nil
            }
        } message: { pendingProject in
            Text("Remove \(pendingProject.name) at \(pendingProject.remotePath)?")
        }
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
            .disabled(!canCreateThread)
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.section.new-thread.\(project.id)")

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
        .accessibilityIdentifier("project.section.toggle.\(project.id)")
        .contextMenu {
            Button("New Thread") {
                onNewThread(project)
            }

            Button("Copy Project Name") {
                copyToPasteboard(project.name)
            }

            Button("Copy Path") {
                copyToPasteboard(project.remotePath)
            }

            Divider()

            Button("Remove Repository", role: .destructive) {
                projectPendingRemoval = project
            }
        }
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
            .tag(thread.id)
            .accessibilityIdentifier("thread.row.\(thread.id)")
            .background(isSelected ? Color.white.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contextMenu {
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
