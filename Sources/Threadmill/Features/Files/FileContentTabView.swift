import SwiftUI

struct FileContentTabView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @Binding var showTree: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            contentArea
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            Button {
                showTree.toggle()
            } label: {
                Image(systemName: showTree ? "sidebar.leading" : "sidebar.right")
                    .font(.caption)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                viewModel.selectPreviousFile()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!viewModel.canSelectPreviousFile)
            .opacity(viewModel.canSelectPreviousFile ? 1 : 0.35)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(viewModel.openFiles) { file in
                            tab(for: file)
                                .id(file.id)
                        }
                    }
                }
                .onChange(of: viewModel.selectedFileId) { _, selected in
                    guard let selected else {
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }

            Button {
                viewModel.selectNextFile()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!viewModel.canSelectNextFile)
            .opacity(viewModel.canSelectNextFile ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tab(for file: OpenFileInfo) -> some View {
        let isSelected = file.id == viewModel.selectedFileId

        return TabContainer(isSelected: isSelected) {
            viewModel.selectFile(id: file.id)
        } content: {
            HStack(spacing: 6) {
                TabLabel(title: file.name, icon: nil)
                TabCloseButton {
                    viewModel.closeFile(id: file.id)
                }
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let selectedFile = viewModel.selectedOpenFile {
            ScrollView {
                Text(selectedFile.content)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.lastErrorMessage {
            VStack(spacing: 10) {
                ContentUnavailableView(
                    "Unable to open file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                Button("Retry") {
                    Task {
                        await viewModel.retryLastOpenFile()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No file selected",
                systemImage: "doc",
                description: Text("Open a file from the tree to preview it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
