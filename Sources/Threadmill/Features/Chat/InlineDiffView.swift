import ACPModel
import SwiftUI

struct InlineDiffView: View {
    private let lines: [DiffLine]

    @State private var isExpanded = false

    private let previewCount = 8

    init(text: String) {
        lines = DiffLine.parse(text: text)
    }

    init(diff: ToolCallDiff) {
        lines = DiffLine.from(diff: diff)
    }

    private var visibleLines: [DiffLine] {
        if isExpanded || lines.count <= previewCount {
            return lines
        }
        return Array(lines.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diff")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if lines.count > previewCount {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.numberLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(line.background)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .textSelection(.enabled)

            if !isExpanded, lines.count > previewCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded = true
                    }
                } label: {
                    Text("Show \(lines.count - previewCount) more lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    static func looksLikeUnifiedDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { $0.hasPrefix("@@") } || (lines.contains { $0.hasPrefix("+") } && lines.contains { $0.hasPrefix("-") })
    }
}

private struct DiffLine: Identifiable {
    enum Kind {
        case context
        case added
        case removed
        case meta
    }

    let id = UUID()
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    let kind: Kind

    var numberLabel: String {
        let old = oldNumber.map(String.init) ?? ""
        let new = newNumber.map(String.init) ?? ""
        return "\(old)|\(new)"
    }

    var background: Color {
        switch kind {
        case .added:
            return Color.green.opacity(0.15)
        case .removed:
            return Color.red.opacity(0.15)
        case .context, .meta:
            return .clear
        }
    }

    static func parse(text: String) -> [DiffLine] {
        var old = 1
        var new = 1
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { line in
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    defer { new += 1 }
                    return DiffLine(oldNumber: nil, newNumber: new, text: line, kind: .added)
                }
                if line.hasPrefix("-") && !line.hasPrefix("---") {
                    defer { old += 1 }
                    return DiffLine(oldNumber: old, newNumber: nil, text: line, kind: .removed)
                }
                if line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---") {
                    return DiffLine(oldNumber: nil, newNumber: nil, text: line, kind: .meta)
                }
                defer {
                    old += 1
                    new += 1
                }
                return DiffLine(oldNumber: old, newNumber: new, text: line, kind: .context)
            }
    }

    static func from(diff: ToolCallDiff) -> [DiffLine] {
        let oldLines = diff.oldText?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        let newLines = diff.newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [DiffLine] = [
            DiffLine(oldNumber: nil, newNumber: nil, text: "--- \(diff.path)", kind: .meta),
            DiffLine(oldNumber: nil, newNumber: nil, text: "+++ \(diff.path)", kind: .meta),
        ]

        let maxCount = max(oldLines.count, newLines.count)
        var oldIndex = 1
        var newIndex = 1

        for i in 0 ..< maxCount {
            let oldLine = i < oldLines.count ? oldLines[i] : nil
            let newLine = i < newLines.count ? newLines[i] : nil

            switch (oldLine, newLine) {
            case let (.some(oldValue), .some(newValue)):
                if oldValue == newValue {
                    lines.append(DiffLine(oldNumber: oldIndex, newNumber: newIndex, text: " \(newValue)", kind: .context))
                } else {
                    lines.append(DiffLine(oldNumber: oldIndex, newNumber: nil, text: "-\(oldValue)", kind: .removed))
                    lines.append(DiffLine(oldNumber: nil, newNumber: newIndex, text: "+\(newValue)", kind: .added))
                }
                oldIndex += 1
                newIndex += 1
            case let (.some(oldValue), .none):
                lines.append(DiffLine(oldNumber: oldIndex, newNumber: nil, text: "-\(oldValue)", kind: .removed))
                oldIndex += 1
            case let (.none, .some(newValue)):
                lines.append(DiffLine(oldNumber: nil, newNumber: newIndex, text: "+\(newValue)", kind: .added))
                newIndex += 1
            case (.none, .none):
                break
            }
        }

        return lines
    }
}
