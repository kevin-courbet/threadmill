import SwiftUI

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

    @State private var isExpanded = true
    @State private var isHeaderHovered = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if displayedThreads.isEmpty {
                Text("No threads yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
                    .padding(.vertical, 3)
            } else {
                ForEach(displayedThreads) { thread in
                    threadRow(thread)
                }
            }
        } label: {
            header
        }
        .disclosureGroupStyle(ProjectSectionDisclosureStyle())
        .padding(.vertical, 4)
        .accessibilityIdentifier("project.section.\(project.id)")
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

            Text("\(threads.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.06), in: Capsule())

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
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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

private struct ProjectSectionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.14), value: configuration.isExpanded)
    }
}
