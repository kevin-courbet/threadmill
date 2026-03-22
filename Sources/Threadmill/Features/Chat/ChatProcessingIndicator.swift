import AppKit
import SwiftUI

struct ChatProcessingIndicator: View {
    let thoughtText: String

    private var displayText: String {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking..." : trimmed
    }

    var body: some View {
        HStack(spacing: 8) {
            ChatProcessingSpinner()
            ShimmerEffect(text: displayText, font: .systemFont(ofSize: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .foregroundStyle(.secondary)
    }
}

private struct ChatProcessingSpinner: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.86)
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 13, height: 13)
            .keyframeAnimator(initialValue: 0.0, trigger: animate) { content, value in
                content.rotationEffect(.degrees(value))
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(120, duration: 0.28)
                    CubicKeyframe(250, duration: 0.28)
                    CubicKeyframe(360, duration: 0.24)
                }
            }
            .onAppear {
                animate = true
            }
    }
}
