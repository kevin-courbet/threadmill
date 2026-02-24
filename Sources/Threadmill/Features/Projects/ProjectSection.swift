import SwiftUI

struct ProjectSection: View {
    let project: Project
    let threads: [ThreadModel]
    @Binding var selectedThreadID: String?
    let onNewThread: (Project) -> Void
    let onHideThread: (ThreadModel) -> Void
    let onCloseThread: (ThreadModel) -> Void
    let onReopenThread: (ThreadModel) -> Void

    @State private var isExpanded = true

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if threads.isEmpty {
                    Text("No threads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                } else {
                    ForEach(threads) { thread in
                        Button {
                            selectedThreadID = thread.id
                        } label: {
                            ThreadRow(thread: thread)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .background(selectedThreadID == thread.id ? Color.accentColor.opacity(0.15) : .clear)
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
            } label: {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.headline)

                    Spacer(minLength: 0)

                    Button {
                        onNewThread(project)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
