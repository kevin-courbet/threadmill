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

    var body: some View {
        VStack(spacing: 8) {
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
                .buttonStyle(.borderless)
                .disabled(isGenerating)

                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(isGenerating)
                    .accessibilityIdentifier("chat.input.text")

                VStack(spacing: 8) {
                    if isGenerating {
                        Button("Abort") {
                            onAbort()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("chat.input.abort")
                    }

                    Button("Send") {
                        onSend()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("chat.input.send")
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
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
