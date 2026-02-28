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
        HStack(spacing: 4) {
            tabIconButton(systemName: showTree ? "sidebar.trailing" : "sidebar.leading", frameSize: 36) {
                showTree.toggle()
            }

            tabIconButton(systemName: "chevron.left") {
                viewModel.selectPreviousFile()
            }
            .disabled(!viewModel.canSelectPreviousFile || viewModel.openFiles.count <= 1)
            .opacity((viewModel.canSelectPreviousFile && viewModel.openFiles.count > 1) ? 1 : 0.35)

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

            tabIconButton(systemName: "chevron.right") {
                viewModel.selectNextFile()
            }
            .disabled(!viewModel.canSelectNextFile || viewModel.openFiles.count <= 1)
            .opacity((viewModel.canSelectNextFile && viewModel.openFiles.count > 1) ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tab(for file: OpenFileInfo) -> some View {
        let isSelected = file.id == viewModel.selectedFileId

        return TabContainer(isSelected: isSelected, style: .topBorder) {
            viewModel.selectFile(id: file.id)
        } content: {
            HStack(spacing: 6) {
                FileIconView(fileName: file.name, size: 14)
                TabLabel(title: file.name, icon: nil)
                TabCloseButton {
                    viewModel.closeFile(id: file.id)
                }
            }
            .frame(minWidth: 120, maxWidth: 260)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let selectedFile = viewModel.selectedOpenFile {
            if selectedFile.content.isEmpty {
                ContentUnavailableView(
                    "File is empty",
                    systemImage: "doc.text",
                    description: Text("\(selectedFile.name) has no content.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReadOnlyCodeEditor(
                    content: selectedFile.content,
                    filePath: selectedFile.path
                )
                .id(selectedFile.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.isOpeningFile {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading file...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No files open")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Select a file from the tree to open")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabIconButton(systemName: String, frameSize: CGFloat = 24, action: @escaping () -> Void) -> some View {
        TabBarIconButton(systemName: systemName, frameSize: frameSize, action: action)
    }
}

private struct ReadOnlyCodeEditor: View {
    let content: String
    let filePath: String

    var body: some View {
        CodeEditorView(
            text: content,
            language: LanguageDetection.language(for: filePath)
        )
    }
}

private struct TabBarIconButton: View {
    let systemName: String
    let frameSize: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: frameSize, height: frameSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? Color(nsColor: .separatorColor).opacity(0.35) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
    }
}
