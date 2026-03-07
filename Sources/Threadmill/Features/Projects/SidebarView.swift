import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var showingAddRepoSheet: Bool
    @State private var newThreadRepo: Repo?

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1"
    }

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
                ForEach(sidebarItems) { item in
                    switch item {
                    case .repo(let repo, let threads):
                        RepoSection(
                            repo: repo,
                            threads: threads,
                            canCreateThread: !appState.remotes.isEmpty,
                            selectedThreadID: $bindableState.selectedThreadID,
                            onNewThread: { repo in
                                newThreadRepo = repo
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
                            }
                        )

                    case .project(let project, let threads):
                        ProjectSection(
                            project: project,
                            threads: threads,
                            canCreateThread: preselectedRepoForNewThread(from: project, repos: appState.repos) != nil && !appState.remotes.isEmpty,
                            selectedThreadID: $bindableState.selectedThreadID,
                            onNewThread: { project in
                                newThreadRepo = preselectedRepoForNewThread(from: project, repos: appState.repos)
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

            if isUITestMode {
                VStack(spacing: 2) {
                    Button("Automation Add Project") {
                        showingAddRepoSheet = true
                    }
                    .accessibilityIdentifier("automation.open-add-project")
                    .accessibilityLabel("Automation Open Add Project")

                    Button("Automation New Thread") {
                        newThreadRepo = appState.repos.first
                    }
                    .accessibilityIdentifier("automation.open-new-thread")
                    .accessibilityLabel("Automation Open New Thread")

                    ForEach(appState.threads) { thread in
                        Button("Automation Select \(thread.id)") {
                            bindableState.selectedThreadID = thread.id
                        }
                        .accessibilityIdentifier("automation.select-thread.\(thread.id)")
                        .accessibilityLabel("Automation Select \(thread.id)")
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .background(sidebarBackground)
        .sheet(
            isPresented: Binding(
                get: { newThreadRepo != nil },
                set: { isPresented in
                    if !isPresented {
                        newThreadRepo = nil
                    }
                }
            )
        ) {
            if let newThreadRepo {
                NewThreadSheet(repo: newThreadRepo)
            }
        }
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

func preselectedRepoForNewThread(from project: Project, repos: [Repo]) -> Repo? {
    guard let repoID = project.repoId else {
        return nil
    }
    return repos.first(where: { $0.id == repoID })
}
