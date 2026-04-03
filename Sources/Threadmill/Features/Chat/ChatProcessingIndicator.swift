import AppKit
import SwiftUI

/// Compact inline indicator — spinner + thought text + live elapsed timer.
struct ChatProcessingIndicator: View {
    let thoughtText: String
    var turnStartedAt: Date?

    private var displayText: String {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking\u{2026}" : trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            ChatProcessingSpinner(size: 10)
                .frame(width: 10, height: 10)

            Text(displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatTokens.textMuted)
                .lineLimit(1)

            if let turnStartedAt {
                ElapsedTimerText(since: turnStartedAt)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(ChatTokens.surfaceCard)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(ChatTokens.borderSubtle, lineWidth: 0.5)
        )
    }
}

/// Live-updating elapsed time label. Ticks every second via TimelineView.
private struct ElapsedTimerText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(since)
            Text(Self.format(elapsed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ChatTokens.textFaint)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 {
            return "\(s)s"
        }
        return "\(s / 60)m \(s % 60)s"
    }
}

private struct ChatProcessingSpinner: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(
                AngularGradient(
                    colors: [.accentColor.opacity(0.1), .accentColor, .accentColor.opacity(0.15)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .keyframeAnimator(initialValue: 0.0, repeating: true) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(120, duration: 0.18)
                    CubicKeyframe(240, duration: 0.24)
                    CubicKeyframe(360, duration: 0.34)
                }
            }
    }
}
