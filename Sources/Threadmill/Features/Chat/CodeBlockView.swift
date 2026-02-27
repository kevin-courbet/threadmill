import AppKit
import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var copied = false

    private let collapseThreshold = 12
    private let previewLines = 8

    private var lines: [String] {
        code.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var isCollapsible: Bool {
        lines.count > collapseThreshold
    }

    private var visibleLines: [String] {
        if isCollapsible, !isExpanded {
            return Array(lines.prefix(previewLines))
        }
        return lines
    }

    private var normalizedLanguage: String {
        guard let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "text"
        }
        return language
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(normalizedLanguage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("\(lines.count) lines")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if isCollapsible {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()
                .overlay(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14))

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleLines.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)

                            Text(visibleLines[index].isEmpty ? " " : visibleLines[index])
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .foregroundStyle(codeForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isExpanded ? 340 : 210)
            .textSelection(.enabled)

            if isCollapsible, !isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded = true
                    }
                } label: {
                    Text("\(lines.count - previewLines) more lines")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var codeBackground: Color {
        colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.98)
    }

    private var codeForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.86)
    }
}
