import AppKit
import SwiftUI

/// Compact inline indicator — animated spinner orb + live elapsed timer. No text label.
struct ChatProcessingIndicator: View {
    var turnStartedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            PulsingOrb(size: 12)
                .frame(width: 12, height: 12)

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

/// Animated orb: spinning arc with pulsing glow halo.
private struct PulsingOrb: View {
    let size: CGFloat

    @State private var glowPhase: Double = 0

    var body: some View {
        ZStack {
            // Glow halo
            Circle()
                .fill(Color.accentColor.opacity(0.15 + 0.1 * sin(glowPhase)))
                .frame(width: size + 4, height: size + 4)

            // Spinning arc
            Circle()
                .trim(from: 0.1, to: 0.7)
                .stroke(
                    AngularGradient(
                        colors: [
                            .accentColor.opacity(0.05),
                            .accentColor,
                            .accentColor.opacity(0.1),
                        ],
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

            // Center dot
            Circle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3, height: 3)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                glowPhase = .pi
            }
        }
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
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
