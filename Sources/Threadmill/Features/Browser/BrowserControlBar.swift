import SwiftUI

struct BrowserControlBar: View {
    @Binding var url: String
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let loadingProgress: Double

    let focusURLTrigger: Int
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onNavigate: (String) -> Void

    @State private var editingURL = ""
    @FocusState private var isURLFieldFocused: Bool

    private var urlInputBinding: Binding<String> {
        Binding(
            get: { isURLFieldFocused ? editingURL : url },
            set: { editingURL = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                navigationButton(action: onBack, icon: "chevron.left", disabled: !canGoBack)
                navigationButton(action: onForward, icon: "chevron.right", disabled: !canGoForward)
                navigationButton(action: onReload, icon: "arrow.clockwise", disabled: false)
            }

            TextField("Enter URL", text: urlInputBinding)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .onChange(of: isURLFieldFocused) { _, focused in
                    if focused {
                        editingURL = url
                    }
                }
                .onSubmit(handleURLSubmit)
                .onChange(of: focusURLTrigger) { _, _ in
                    isURLFieldFocused = true
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottomLeading) {
            if isLoading && loadingProgress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * loadingProgress, height: 2)
                        .animation(.linear(duration: 0.12), value: loadingProgress)
                }
                .frame(height: 2)
            }
        }
    }

    private func navigationButton(action: @escaping () -> Void, icon: String, disabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func handleURLSubmit() {
        let normalizedURL = Self.normalizeURL(editingURL)
        guard !normalizedURL.isEmpty else {
            return
        }

        url = normalizedURL
        onNavigate(normalizedURL)
        isURLFieldFocused = false
    }

    private static func normalizeURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if trimmed.contains("://") || trimmed.hasPrefix("about:") {
            return trimmed
        }

        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            return "http://\(trimmed)"
        }

        return "https://\(trimmed)"
    }
}
