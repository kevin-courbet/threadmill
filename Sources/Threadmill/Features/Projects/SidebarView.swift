import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var showingAddProjectSheet: Bool
    @State private var showingCloneRepoSheet = false
    @State private var newThreadProjectID: String?

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["THREADMILL_UI_TEST_MODE"] == "1"
    }

    private var sidebarBackground: Color {
        Color(red: 0.06, green: 0.07, blue: 0.09)
    }

    var body: some View {
        @Bindable var bindableState = appState

        VStack(spacing: 0) {
            List {
                ForEach(appState.projectsWithThreads, id: \.0.id) { project, threads in
                    ProjectSection(
                        project: project,
                        threads: threads,
                        selectedThreadID: $bindableState.selectedThreadID,
                        onNewThread: { project in
                            newThreadProjectID = preselectedProjectIDForNewThread(from: project)
                        },
                        onCancelThreadCreation: { thread in
                            Task {
                                await appState.cancelThreadCreation(threadID: thread.id)
                            }
                        },
                        onHideThread: { thread in
                            Task {
                                await appState.hideThread(threadID: thread.id)
                            }
                        },
                        onCloseThread: { thread in
                            Task {
                                await appState.closeThread(threadID: thread.id)
                            }
                        },
                        onReopenThread: { thread in
                            Task {
                                await appState.reopenThread(threadID: thread.id)
                            }
                        }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(sidebarBackground)
            .accessibilityIdentifier("sidebar.projects-list")

            HStack {
                Menu {
                    Button("Open project") {
                        showingAddProjectSheet = true
                    }
                    .accessibilityIdentifier("sidebar.open-project-button")

                    Button("Clone repo") {
                        showingCloneRepoSheet = true
                    }
                    .accessibilityIdentifier("sidebar.clone-repo-button")
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
                .accessibilityIdentifier("sidebar.add-repository-menu")

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.02))

            if isUITestMode {
                VStack(spacing: 2) {
                    Button("Automation Add Project") {
                        showingAddProjectSheet = true
                    }
                    .accessibilityIdentifier("automation.open-add-project")
                    .accessibilityLabel("Automation Open Add Project")

                    Button("Automation New Thread") {
                        newThreadProjectID = appState.projects.first?.id
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
        .sheet(isPresented: $showingCloneRepoSheet) {
            CloneRepoSheet()
        }
        .sheet(
            isPresented: Binding(
                get: { newThreadProjectID != nil },
                set: { isPresented in
                    if !isPresented {
                        newThreadProjectID = nil
                    }
                }
            )
        ) {
            NewThreadSheet(preselectedProjectID: newThreadProjectID)
        }
        .onChange(of: appState.selectedThreadID) { _, _ in
            appState.selectedPreset = appState.presets.first?.name
            Task {
                await appState.attachSelectedPreset()
            }
        }
    }
}

func preselectedProjectIDForNewThread(from project: Project) -> String {
    project.id
}
