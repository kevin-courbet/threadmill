import SwiftUI

struct FileTreeView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                treeRows(for: viewModel.currentPath, level: 0)
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func treeRows(for path: String, level: Int) -> AnyView {
        let entries = viewModel.entries(for: path)

        return AnyView(
            Group {
                if entries.isEmpty {
                    if viewModel.isDirectoryLoading(path) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(level) * 16 + 10)
                        .padding(.vertical, 4)
                    } else if level == 0 {
                        Text("No files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.vertical, 4)
                    }
                }

                ForEach(entries) { entry in
                    row(for: entry, level: level)

                    if entry.isDirectory, viewModel.expandedPaths.contains(entry.path) {
                        treeRows(for: entry.path, level: level + 1)
                    }
                }
            }
        )
    }

    private func row(for entry: FileBrowserEntry, level: Int) -> some View {
        let isSelected = viewModel.selectedOpenFile?.path == entry.path

        return HStack(spacing: 6) {
            Group {
                if entry.isDirectory {
                    Image(systemName: viewModel.expandedPaths.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)

            Image(systemName: iconName(for: entry))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(level) * 16 + 10)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                if entry.isDirectory {
                    await viewModel.toggleDirectory(entry)
                } else {
                    await viewModel.openFile(path: entry.path)
                }
            }
        }
    }

    private func iconName(for entry: FileBrowserEntry) -> String {
        if entry.isDirectory {
            return "folder"
        }

        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "swift": return "swift"
        case "rs": return "r.square"
        case "md": return "doc.plaintext"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc.text"
        }
    }
}
