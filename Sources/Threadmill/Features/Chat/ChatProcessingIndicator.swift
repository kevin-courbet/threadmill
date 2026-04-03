import AppKit
import SwiftUI

struct ChatProcessingIndicator: View {
    let thoughtText: String

    private let spinnerSize: CGFloat = 12

    private var displayText: String {
        let trimmed = thoughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking..." : trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            ChatProcessingSpinner(size: spinnerSize)
                .frame(width: spinnerSize, height: spinnerSize)

            ShimmerEffect(text: displayText, font: .systemFont(ofSize: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .foregroundStyle(.secondary)
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
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
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
