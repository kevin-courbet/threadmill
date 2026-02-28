import SwiftUI

struct FileIconView: View {
    let fileName: String
    let isDirectory: Bool
    let size: CGFloat

    init(fileName: String, isDirectory: Bool = false, size: CGFloat = 12) {
        self.fileName = fileName
        self.isDirectory = isDirectory
        self.size = size
    }

    var body: some View {
        let spec = symbolSpec
        Image(systemName: spec.name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(spec.color)
            .frame(width: size + 2, height: size + 2)
    }

    private var symbolSpec: (name: String, color: Color) {
        if isDirectory {
            return ("folder.fill", .blue)
        }

        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "swift":
            return ("swift", .orange)
        case "ts", "tsx":
            return ("t.square", .blue)
        case "js", "jsx", "mjs", "cjs":
            return ("j.square", .yellow)
        case "py":
            return ("p.square", .green)
        case "rs":
            return ("r.square", .orange)
        case "go":
            return ("g.square", .cyan)
        case "html", "htm":
            return ("globe", .orange)
        case "css", "scss", "sass", "less":
            return ("paintbrush", .blue)
        case "json", "yaml", "yml":
            return ("curlybraces", .yellow)
        case "md", "markdown":
            return ("doc.richtext", .blue)
        case "sh", "bash", "zsh", "fish":
            return ("terminal", .green)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif":
            return ("photo", .purple)
        default:
            return ("doc", .secondary)
        }
    }
}
