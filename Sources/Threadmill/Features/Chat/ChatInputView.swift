import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void
    let onAbort: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var measuredEditorHeight: CGFloat = 44

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private var editorHeight: CGFloat {
        min(140, max(44, measuredEditorHeight))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if isGenerating {
                    Button {
                        onAbort()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.input.abort")
                } else {
                    Button {
                        onSend()
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(canSend ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("chat.input.send")
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Ask about this thread...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $text)
                        .font(.body)
                        .focused($inputFocused)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .frame(height: editorHeight)
                        .accessibilityIdentifier("chat.input.text")

                    Text(measurementText)
                        .font(.body)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .frame(width: max(0, geometry.size.width - 8), alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ChatInputHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .hidden()
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.3),
                        lineWidth: inputFocused ? 1 : 0.5
                    )
                    .animation(.easeInOut(duration: 0.18), value: inputFocused)
            )
            .onPreferenceChange(ChatInputHeightPreferenceKey.self) { height in
                measuredEditorHeight = height
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
        )
    }

    private var measurementText: String {
        let value = text.isEmpty ? " " : text
        return value + "\n"
    }
}

private struct ChatInputHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
