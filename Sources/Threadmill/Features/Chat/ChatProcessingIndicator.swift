import AppKit
import SwiftUI

struct ChatProcessingIndicator: View {
    let thoughtText: String

    private var displayText: String {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking..." : trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)

            Text(displayText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .foregroundStyle(.secondary)
    }
}
