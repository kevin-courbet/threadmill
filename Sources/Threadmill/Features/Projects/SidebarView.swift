import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddProjectSheet = false
    @State private var showingNewThreadSheet = false

    var body: some View {
        @Bindable var bindableState = appState

        VStack(spacing: 0) {
            List {
                ForEach(appState.projectsWithThreads, id: \.0.id) { project, threads in
                    ProjectSection(
                        project: project,
                        threads: threads,
                        selectedThreadID: $bindableState.selectedThreadID,
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
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button("+ New Thread") {
                    showingNewThreadSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Spacer()

                Button("+ Add Project") {
                    showingAddProjectSheet = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationTitle("Projects")
        .sheet(isPresented: $showingAddProjectSheet) {
            AddProjectSheet()
        }
        .sheet(isPresented: $showingNewThreadSheet) {
            NewThreadSheet()
        }
        .onChange(of: appState.selectedThreadID) { _, _ in
            appState.selectedPreset = appState.presets.first?.name
            Task {
                await appState.attachSelectedPreset()
            }
        }
    }
}
