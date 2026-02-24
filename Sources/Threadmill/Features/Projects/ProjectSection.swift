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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No threads yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Press + to create one")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                        .padding(.leading, 20)
                } else {
                    ForEach(threads) { thread in
                        let isSelected = selectedThreadID == thread.id
                        Button {
                            selectedThreadID = thread.id
                        } label: {
                            ThreadRow(thread: thread)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("thread.row.\(thread.id)")
                        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
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
            } label: {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.headline)
                    Text("(\(threads.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button {
                        onNewThread(project)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project.section.new-thread.\(project.id)")
                }
            }
            .accessibilityIdentifier("project.section.\(project.id)")
        }
    }
}
