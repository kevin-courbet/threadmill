import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let sessions: [OCSession]
    let currentSessionID: String?
    let isGenerating: Bool
    let onSelectSession: (String) -> Void
    let onCreateSession: () -> Void
    let onSend: () -> Void
    let onAbort: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("Session", selection: sessionSelectionBinding) {
                    if sessions.isEmpty {
                        Text("No sessions").tag("")
                    }
                    ForEach(sessions) { session in
                        Text(displayName(for: session))
                            .tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)
                .disabled(sessions.isEmpty || isGenerating)

                Button {
                    onCreateSession()
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerating)

                Spacer(minLength: 0)

                if isGenerating {
                    Button("Abort") {
                        onAbort()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("chat.input.abort")
                }

                Button {
                    onSend()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("chat.input.send")
            }

            TextField("Ask about this thread...", text: $text, axis: .vertical)
                .lineLimit(1 ... 8)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .disabled(isGenerating)
                .accessibilityIdentifier("chat.input.text")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
                .overlay(Color.primary.opacity(0.12))
        }
    }

    private var sessionSelectionBinding: Binding<String> {
        Binding(
            get: { currentSessionID ?? sessions.first?.id ?? "" },
            set: { newID in
                guard !newID.isEmpty else {
                    return
                }
                onSelectSession(newID)
            }
        )
    }

    private func displayName(for session: OCSession) -> String {
        if !session.title.isEmpty {
            return session.title
        }
        if let slug = session.slug, !slug.isEmpty {
            return slug
        }
        return session.id
    }
}
