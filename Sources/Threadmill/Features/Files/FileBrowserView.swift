import SwiftUI

struct FileBrowserView: View {
    @AppStorage("fileBrowserShowTree") private var showTree = true
    @AppStorage("fileBrowserTreeWidth") private var treeWidth: Double = 250
    @StateObject private var viewModel: FileBrowserViewModel
    @Environment(\.closeActiveTabTrigger) private var closeActiveTabTrigger
    @Environment(\.selectNextTabTrigger) private var selectNextTabTrigger
    @Environment(\.selectPreviousTabTrigger) private var selectPreviousTabTrigger

    let connectionStatus: ConnectionStatus

    private let minTreeWidth: CGFloat = 150
    private let maxTreeWidth: CGFloat = 400

    init(rootPath: String, fileService: any FileBrowsing, connectionStatus: ConnectionStatus) {
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(rootPath: rootPath, fileService: fileService)
        )
        self.connectionStatus = connectionStatus
    }

    var body: some View {
        Group {
            if showTree {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        FileTreeHeader(rootPath: viewModel.rootPath)
                        Divider()
                        FileTreeView(viewModel: viewModel)
                    }
                    .frame(width: CGFloat(treeWidth))

                    FileBrowserDivider(
                        treeWidth: $treeWidth,
                        minWidth: minTreeWidth,
                        maxWidth: maxTreeWidth
                    )

                    VStack(spacing: 0) {
                        FileTabBar(viewModel: viewModel, showTree: $showTree)
                        Divider()
                        FileContentArea(viewModel: viewModel)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    FileTabBar(viewModel: viewModel, showTree: $showTree)
                    Divider()
                    FileContentArea(viewModel: viewModel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await viewModel.loadInitialDirectoryIfNeeded()
        }
        .onChange(of: connectionStatus) { _, newStatus in
            if newStatus.isConnected {
                Task {
                    await viewModel.reloadAfterConnect()
                }
            }
        }
        .onChange(of: closeActiveTabTrigger) { _, _ in
            guard let fileID = viewModel.selectedFileId else { return }
            viewModel.closeFile(id: fileID)
        }
        .onChange(of: selectNextTabTrigger) { _, _ in
            viewModel.selectNextFile()
        }
        .onChange(of: selectPreviousTabTrigger) { _, _ in
            viewModel.selectPreviousFile()
        }
    }

}

/// Tree header matching the tab bar height for visual alignment.
private struct FileTreeHeader: View {
    let rootPath: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(rootPath.split(separator: "/").last.map(String.init) ?? rootPath)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Draggable divider that stays within the content area (does not bleed into toolbar).
private struct FileBrowserDivider: View {
    @Binding var treeWidth: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isDragging = false
    @State private var dragStartWidth: Double = 0

    var body: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = treeWidth
                        }
                        let proposed = dragStartWidth + Double(value.translation.width)
                        treeWidth = min(max(proposed, Double(minWidth)), Double(maxWidth))
                    }
                    .onEnded { _ in
                        isDragging = false
                        NSCursor.pop()
                    }
            )
    }
}
