import AppKit
import SwiftUI

/// Compact inline indicator — small pill hugging its content, left-aligned.
struct ChatProcessingIndicator: View {
    let thoughtText: String

    private var displayText: String {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking\u{2026}" : trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            ChatProcessingSpinner(size: 10)
                .frame(width: 10, height: 10)

            ShimmerEffect(text: displayText, font: .systemFont(ofSize: 11, weight: .medium))
                .fixedSize()
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
