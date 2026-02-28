import SwiftUI

struct FileBrowserView: View {
    @AppStorage("fileBrowserShowTree") private var showTree = true
    @StateObject private var viewModel: FileBrowserViewModel

    init(rootPath: String, fileService: any FileBrowsing) {
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(rootPath: rootPath, fileService: fileService)
        )
    }

    var body: some View {
        Group {
            if showTree {
                HSplitView {
                    FileTreeView(viewModel: viewModel)
                        .frame(minWidth: 150, idealWidth: 280, maxWidth: 400)

                    FileContentTabView(viewModel: viewModel, showTree: $showTree)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                FileContentTabView(viewModel: viewModel, showTree: $showTree)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await viewModel.loadInitialDirectoryIfNeeded()
        }
    }
}
