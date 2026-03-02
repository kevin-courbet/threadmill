import AppKit
import SwiftUI
import CodeEditLanguages

/// Full-width tab bar for file browser — spans across tree and content.
struct FileTabBar: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @Binding var showTree: Bool

    var body: some View {
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

    private func tabIconButton(systemName: String, frameSize: CGFloat = 24, action: @escaping () -> Void) -> some View {
        TabBarIconButton(systemName: systemName, frameSize: frameSize, action: action)
    }
}

/// Content area for file browser — displays selected file or empty/error states.
struct FileContentArea: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    @ViewBuilder
    var body: some View {
        if let selectedFile = viewModel.selectedOpenFile {
            VStack(spacing: 0) {
                BreadcrumbBar(filePath: selectedFile.path, basePath: viewModel.rootPath)
                Divider()
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
}

private struct ReadOnlyCodeEditor: View {
    let content: String
    let filePath: String

    var body: some View {
        CodeEditorView(
            content: content,
            language: LanguageDetection.language(for: filePath)
        )
    }
}

private struct BreadcrumbBar: View {
    let filePath: String
    let basePath: String

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            let components = breadcrumbComponents()
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    Text(component)
                        .font(.system(size: 11))
                        .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { availableWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, newValue in
                            availableWidth = newValue
                        }
                }
            )

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func breadcrumbComponents() -> [String] {
        let relative = relativePath()
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count > 2, availableWidth > 0 else { return parts }

        if totalWidth(for: parts) <= availableWidth { return parts }

        let first = parts[0]
        let last = parts[parts.count - 1]
        var result = [first, "...", last]
        if totalWidth(for: result) > availableWidth {
            result = ["...", last]
            return totalWidth(for: result) > availableWidth ? [last] : result
        }

        for index in stride(from: parts.count - 2, through: 1, by: -1) {
            let candidate = [first, "..."] + parts[index...]
            if totalWidth(for: candidate) <= availableWidth {
                result = candidate
            } else {
                break
            }
        }
        return result
    }

    private func relativePath() -> String {
        let normalizedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let normalizedFile = filePath.hasSuffix("/") ? String(filePath.dropLast()) : filePath
        if normalizedFile.hasPrefix(normalizedBase + "/") {
            return String(normalizedFile.dropFirst(normalizedBase.count + 1))
        }
        return filePath
    }

    private func totalWidth(for components: [String]) -> CGFloat {
        let componentWidth = components.reduce(0) { $0 + textWidth($1) }
        let chevronCount = max(components.count - 1, 0)
        let elementCount = max(components.count * 2 - 1, 0)
        let spacingCount = max(elementCount - 1, 0)
        return componentWidth + CGFloat(chevronCount) * 8 + CGFloat(spacingCount) * 4
    }

    private func textWidth(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        return (text as NSString).size(withAttributes: attributes).width
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
