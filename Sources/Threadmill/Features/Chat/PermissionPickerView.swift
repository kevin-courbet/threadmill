import AppKit
import SwiftUI

@MainActor
struct PermissionPickerView: View {
    let request: PendingPermissionRequest
    let onApprove: (PendingPermissionRequest, String) -> Void
    let onDeny: (PendingPermissionRequest) -> Void

    @State private var selectedIndex = 0
    @State private var keyboardMonitor: Any?
    @FocusState private var isFocused: Bool

    private var promptText: String {
        let trimmed = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Choose an option" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(promptText)
                .font(.system(size: ChatTokens.bodyFontSize, weight: .medium))
                .foregroundStyle(ChatTokens.textPrimary)
                .lineLimit(3)

            VStack(spacing: 6) {
                ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(index: index, option: option)
                }
            }

            HStack(spacing: 8) {
                Button("Dismiss") {
                    onDeny(request)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ChatTokens.textMuted)

                Text("ESC")
                    .font(.system(size: ChatTokens.metaFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChatTokens.textFaint)

                Spacer(minLength: 0)

                Button("Submit") {
                    submitSelection()
                }
                .buttonStyle(.borderedProminent)

                Text("ENTER")
                    .font(.system(size: ChatTokens.metaFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChatTokens.textFaint)
            }
            .font(.system(size: ChatTokens.captionFontSize, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator.opacity(0.2), lineWidth: 1)
        )
        .focusable()
        .focused($isFocused)
        .onAppear {
            selectedIndex = 0
            isFocused = true
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    private func optionRow(index: Int, option: (id: String, label: String)) -> some View {
        let isSelected = index == selectedIndex
        return HStack(spacing: 8) {
            Text("\(index + 1).")
                .font(.system(size: ChatTokens.captionFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? ChatTokens.textStrong : ChatTokens.textSubtle)
                .frame(width: 26, alignment: .leading)

            Text(option.label)
                .font(.system(size: ChatTokens.bodyFontSize))
                .foregroundStyle(isSelected ? ChatTokens.textStrong : ChatTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? ChatTokens.borderAccent.opacity(0.2) : ChatTokens.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? ChatTokens.borderAccent : ChatTokens.borderSubtle, lineWidth: 1)
        )
        .onTapGesture {
            selectedIndex = index
        }
        .animation(.easeOut(duration: ChatTokens.durFast), value: selectedIndex)
    }

    private func submitSelection() {
        guard request.options.indices.contains(selectedIndex) else { return }
        onApprove(request, request.options[selectedIndex].id)
    }

    private func moveSelection(delta: Int) {
        guard !request.options.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(0, next), request.options.count - 1)
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else { return }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isFocused else { return false }

        if event.keyCode == 126 { // up arrow
            moveSelection(delta: -1)
            return true
        }

        if event.keyCode == 125 { // down arrow
            moveSelection(delta: 1)
            return true
        }

        if event.keyCode == 53 { // escape
            onDeny(request)
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 { // return / keypad enter
            submitSelection()
            return true
        }

        guard let chars = event.charactersIgnoringModifiers, let key = chars.first, key.isNumber else {
            return false
        }

        guard let digit = Int(String(key)), (1...9).contains(digit) else {
            return false
        }

        let index = digit - 1
        guard request.options.indices.contains(index) else {
            return false
        }

        selectedIndex = index
        return true
    }
}
