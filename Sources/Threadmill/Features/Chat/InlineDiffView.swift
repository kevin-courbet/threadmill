import SwiftUI

struct InlineDiffView: View {
    let text: String

    @State private var isExpanded = false

    private let previewCount = 8

    private var lines: [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var visibleLines: [String] {
        if isExpanded || lines.count <= previewCount {
            return lines
        }
        return Array(lines.prefix(previewCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLines.indices, id: \.self) { index in
                        let line = visibleLines[index]
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)

                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(foreground(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(background(for: line))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 220)
            .textSelection(.enabled)

            if !isExpanded, lines.count > previewCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded = true
                    }
                } label: {
                    Text("\(lines.count - previewCount) more lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.96)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.96)
        }
        return Color.white.opacity(0.9)
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.14)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.14)
        }
        return .clear
    }
}
