import SwiftUI

/// Conic-gradient context ring matching CodexMonitor's `.composer-context-ring`.
/// Sweeps from green (100% free) through yellow to red (0% free).
/// Tooltip on hover shows "Context free NN%" or token counts.
struct ContextRingView: View {
    let usedTokens: Int
    let windowSize: Int

    @State private var isHovering = false

    private var contextFreePercent: Double {
        guard windowSize > 0, usedTokens > 0 else { return 100 }
        let used = Double(min(usedTokens, windowSize))
        return max(0, 100 - (used / Double(windowSize)) * 100)
    }

    /// Hue: 120° (green) at 100% free → 0° (red) at 0% free
    private var ringColor: Color {
        let hue = contextFreePercent / 100.0 * 120.0 / 360.0
        return Color(hue: hue, saturation: 0.8, brightness: 0.7)
    }

    private var trackColor: Color {
        ChatTokens.borderHeavy
    }

    private var tooltipText: String {
        guard windowSize > 0, usedTokens > 0 else {
            return "Context free --"
        }
        let pct = Int(contextFreePercent.rounded())
        let usedK = formatTokenCount(usedTokens)
        let totalK = formatTokenCount(windowSize)
        return "Context free \(pct)% (\(usedK)/\(totalK))"
    }

    var body: some View {
        ZStack {
            // Track ring (unfilled portion)
            Circle()
                .stroke(trackColor, lineWidth: 2.5)

            // Filled arc representing used context (sweeps from top)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, 100 - contextFreePercent) / 100.0))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Center dot
            Circle()
                .fill(ringColor.opacity(0.6))
                .frame(width: 4, height: 4)
        }
        .frame(width: 20, height: 20)
        .help(tooltipText)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isHovering) {
            contextPopover
        }
        .animation(.easeOut(duration: 0.3), value: contextFreePercent)
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ringColor)
                    .frame(width: 8, height: 8)
                Text("Context \(Int(contextFreePercent.rounded()))% free")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChatTokens.textPrimary)
            }

            HStack(spacing: 4) {
                Text(formatTokenCount(usedTokens))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatTokens.textMuted)
                Text("/")
                    .font(.system(size: 10))
                    .foregroundStyle(ChatTokens.textFaint)
                Text(formatTokenCount(windowSize))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatTokens.textMuted)
                Text("tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(ChatTokens.textFaint)
            }

            // Warning when hitting the 20% threshold (e.g. 200k/1M for Claude)
            if contextFreePercent <= 20 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(contextFreePercent <= 10 ? ChatTokens.statusError : ChatTokens.statusWarning)
                    Text(contextFreePercent <= 10 ? "Context nearly full" : "Context running low")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(contextFreePercent <= 10 ? ChatTokens.statusError : ChatTokens.statusWarning)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 140)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M"
                : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(count)"
    }
}
