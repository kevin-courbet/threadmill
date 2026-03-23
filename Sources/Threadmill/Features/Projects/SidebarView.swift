import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var showingAddRepoSheet: Bool
    @State private var newThreadTarget: NewThreadTarget?
    @State private var threadPendingClose: ThreadModel?

    private var sidebarBackground: Color {
        Color(red: 0.06, green: 0.07, blue: 0.09)
    }

    // Single ForEach avoids implicit section boundary that macOS List
    // inserts between consecutive ForEach blocks (causes phantom dividers).
    private var sidebarItems: [SidebarItem] {
        appState.reposWithThreads.map { .repo($0.0, $0.1) } +
        appState.projectsWithThreads.map { .project($0.0, $0.1) }
    }

    var body: some View {
        @Bindable var bindableState = appState

        VStack(spacing: 0) {
            List {
                // Pinned threads section — above everything else
                if !appState.pinnedThreads.isEmpty {
                    pinnedSection
                }

                ForEach(sidebarItems) { item in
                    switch item {
                    case .repo(let repo, let threads):
                        RepoSection(
                            repo: repo,
                            linkedProject: linkedProject(for: repo),
                            threads: threads,
                            pinnedThreadIDs: appState.pinnedThreadIDs,
                            canCreateThread: !appState.remotes.isEmpty,
                            selectedThreadID: $bindableState.selectedThreadID,
                            onNewThread: { repo in
                                newThreadTarget = .repo(repo)
                            },
                            onCancelThreadCreation: { thread in
                                Task { await appState.cancelThreadCreation(threadID: thread.id) }
                            },
                            onHideThread: { thread in
                                Task { await appState.hideThread(threadID: thread.id) }
                            },
                            onCloseThread: { thread in
                                Task { await appState.closeThread(threadID: thread.id) }
                            },
                            onReopenThread: { thread in
                                Task { await appState.reopenThread(threadID: thread.id) }
                            },
                            onRemoveProject: { project in
                                Task { await appState.removeProject(projectID: project.id) }
                            },
                            onTogglePin: { thread in
                                appState.togglePin(threadID: thread.id)
                            }
                        )

                    case .project(let project, let threads):
                        ProjectSection(
                            project: project,
                            threads: threads,
                            pinnedThreadIDs: appState.pinnedThreadIDs,
                            canCreateThread: !appState.remotes.isEmpty,
                            selectedThreadID: $bindableState.selectedThreadID,
                            onNewThread: { project in
                                newThreadTarget = .project(project)
                            },
                            onCancelThreadCreation: { thread in
                                Task { await appState.cancelThreadCreation(threadID: thread.id) }
                            },
                            onHideThread: { thread in
                                Task { await appState.hideThread(threadID: thread.id) }
                            },
                            onCloseThread: { thread in
                                Task { await appState.closeThread(threadID: thread.id) }
                            },
                            onReopenThread: { thread in
                                Task { await appState.reopenThread(threadID: thread.id) }
                            },
                            onRemoveProject: { project in
                                Task { await appState.removeProject(projectID: project.id) }
                            },
                            onTogglePin: { thread in
                                appState.togglePin(threadID: thread.id)
                            }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(sidebarBackground)
            .accessibilityIdentifier("sidebar.projects-list")

            HStack {
                Button {
                    showingAddRepoSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add repository")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.add-repository-button")

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))

        }
        .background(sidebarBackground)
        .sheet(
            isPresented: Binding(
                get: { newThreadTarget != nil },
                set: { isPresented in
                    if !isPresented {
                        newThreadTarget = nil
                    }
                }
            )
        ) {
            if let newThreadTarget {
                switch newThreadTarget {
                case .repo(let repo):
                    NewThreadSheet(repo: repo)
                case .project(let project):
                    NewThreadSheet(project: project)
                }
            }
        }
        .alert(
            "Close Thread?",
            isPresented: Binding(
                get: { threadPendingClose != nil },
                set: { if !$0 { threadPendingClose = nil } }
            ),
            presenting: threadPendingClose
        ) { thread in
            Button("Cancel", role: .cancel) { threadPendingClose = nil }
            Button("Close Thread", role: .destructive) {
                Task { await appState.closeThread(threadID: thread.id) }
                threadPendingClose = nil
            }
        } message: { thread in
            Text("Close \(thread.name)? This will stop the tmux session and close its worktree.")
        }
    }

    // MARK: - Pinned Threads

    @ViewBuilder
    private var pinnedSection: some View {
        ForEach(appState.pinnedThreads) { thread in
            pinnedThreadRow(thread)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                .listRowBackground(Color.clear)
                .tag(thread.id)
        }
    }

    @ViewBuilder
    private func pinnedThreadRow(_ thread: ThreadModel) -> some View {
        @Bindable var bindableState = appState

        ThreadRow(
            thread: thread,
            isSelected: appState.selectedThreadID == thread.id,
            isPinned: true,
            onTogglePin: { thread in
                appState.togglePin(threadID: thread.id)
            }
        )
        .onTapGesture {
            bindableState.selectedThreadID = thread.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pinned.thread.row.\(thread.id)")
        .contextMenu {
            Button("Unpin Thread") {
                appState.togglePin(threadID: thread.id)
            }

            if thread.status == .hidden {
                Button("Reopen") {
                    Task { await appState.reopenThread(threadID: thread.id) }
                }
            } else {
                Button("Hide Thread") {
                    Task { await appState.hideThread(threadID: thread.id) }
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

private extension SidebarView {
    func linkedProject(for repo: Repo) -> Project? {
        let candidates = appState.projects.filter { $0.repoId == repo.id }

        if let selectedRemoteID = appState.selectedWorkspaceRemoteID,
           let exactRemoteMatch = candidates.first(where: { $0.remoteId == selectedRemoteID })
        {
            return exactRemoteMatch
        }

        if let activeRemoteID = appState.activeRemoteID,
           let activeRemoteMatch = candidates.first(where: { $0.remoteId == activeRemoteID })
        {
            return activeRemoteMatch
        }

        return candidates.first
    }
}

private enum SidebarItem: Identifiable {
    case repo(Repo, [ThreadModel])
    case project(Project, [ThreadModel])

    var id: String {
        switch self {
        case .repo(let repo, _): return "repo_\(repo.id)"
        case .project(let project, _): return "project_\(project.id)"
        }
    }
}

private enum NewThreadTarget {
    case repo(Repo)
    case project(Project)
}
