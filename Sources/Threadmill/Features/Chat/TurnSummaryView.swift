import SwiftUI

struct TurnSummaryView: View {
    let summary: TurnSummary

    var body: some View {
        HStack(spacing: 12) {
            // Left gradient line (transparent → border)
            gradientDivider(leading: true)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChatTokens.statusSuccess)

            Text("\(summary.toolCount) tool calls \u{00B7} \(summary.durationSeconds)s")
                .font(.system(size: ChatTokens.captionFontSize, weight: .medium))
                .foregroundStyle(ChatTokens.textMuted)

            ForEach(summary.modifiedFiles.prefix(3), id: \.self) { file in
                Text(URL(fileURLWithPath: file).lastPathComponent)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ChatTokens.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ChatTokens.surfaceCard, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(ChatTokens.borderSubtle, lineWidth: 0.5)
                    )
            }

            if summary.modifiedFiles.count > 3 {
                Text("+\(summary.modifiedFiles.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ChatTokens.textFaint)
            }

            // Right gradient line (border → transparent)
            gradientDivider(leading: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Gradient divider matching CodexMonitor's `.turn-complete-line`
    private func gradientDivider(leading: Bool) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: leading
                        ? [.clear, ChatTokens.borderHeavy]
                        : [ChatTokens.borderHeavy, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}
