import AppKit
import SwiftUI

// Design tokens translated from CodexMonitor's CSS design system.
// Dark-first glassmorphic palette with blur surfaces and accent gradients.
enum ChatTokens {

    // MARK: - Surfaces

    /// Chat area background — rgba(8,10,16,0.45)
    static let surfaceMessages = Color(nsColor: NSColor(red: 0.031, green: 0.039, blue: 0.063, alpha: 0.45))
    /// Composer background — rgba(10,14,20,0.45)
    static let surfaceComposer = Color(nsColor: NSColor(red: 0.039, green: 0.055, blue: 0.078, alpha: 0.45))
    /// Agent message bubble — rgba(255,255,255,0.12)
    static let surfaceBubble = Color.white.opacity(0.12)
    /// User message bubble — rgba(77,153,255,0.45)
    static let surfaceBubbleUser = Color(nsColor: NSColor(red: 0.302, green: 0.600, blue: 1.0, alpha: 0.45))
    /// Card background — rgba(255,255,255,0.04)
    static let surfaceCard = Color.white.opacity(0.04)
    /// Elevated card — rgba(255,255,255,0.12)
    static let surfaceCardStrong = Color.white.opacity(0.12)
    /// Popover background — rgba(10,14,20,0.995)
    static let surfacePopover = Color(nsColor: NSColor(red: 0.039, green: 0.055, blue: 0.078, alpha: 0.995))
    /// Command pill bg — same as surfaceCard but slightly more opaque
    static let surfaceCommand = Color.white.opacity(0.06)

    // MARK: - Text

    static let textPrimary = Color(nsColor: NSColor(red: 0.902, green: 0.906, blue: 0.918, alpha: 1.0))
    static let textStrong = Color.white
    static let textMuted = Color.white.opacity(0.70)
    static let textSubtle = Color.white.opacity(0.60)
    static let textFaint = Color.white.opacity(0.50)

    // MARK: - Borders

    /// Default border — rgba(255,255,255,0.08)
    static let borderSubtle = Color.white.opacity(0.08)
    /// Heavy border — rgba(255,255,255,0.14)
    static let borderHeavy = Color.white.opacity(0.14)
    /// Accent border — rgba(100,200,255,0.60)
    static let borderAccent = Color(nsColor: NSColor(red: 0.392, green: 0.784, blue: 1.0, alpha: 0.60))
    /// Accent user border — rgba(100,200,255,0.28)
    static let borderAccentUser = Color(nsColor: NSColor(red: 0.392, green: 0.784, blue: 1.0, alpha: 0.28))

    // MARK: - Status

    static let statusSuccess = Color(nsColor: NSColor(red: 0.471, green: 0.922, blue: 0.745, alpha: 0.95))
    static let statusWarning = Color(nsColor: NSColor(red: 1.0, green: 0.686, blue: 0.333, alpha: 0.95))
    static let statusError = Color(nsColor: NSColor(red: 1.0, green: 0.431, blue: 0.431, alpha: 0.95))

    // MARK: - Accent gradient (primary button: #62b7ff → #4fe3a3)

    static let accentGradient = LinearGradient(
        colors: [
            Color(nsColor: NSColor(red: 0.384, green: 0.718, blue: 1.0, alpha: 1.0)),
            Color(nsColor: NSColor(red: 0.310, green: 0.890, blue: 0.639, alpha: 1.0)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Link color — rgba(196,154,255,0.96)

    static let linkPurple = Color(nsColor: NSColor(red: 0.769, green: 0.604, blue: 1.0, alpha: 0.96))

    // MARK: - Radii

    static let radiusBubble: CGFloat = 18
    static let radiusCard: CGFloat = 16
    static let radiusToolCall: CGFloat = 16
    static let radiusComposer: CGFloat = 20
    static let radiusPill: CGFloat = 999
    static let radiusButton: CGFloat = 10
    static let radiusPopover: CGFloat = 10
    static let radiusCodeBlock: CGFloat = 10
    static let radiusCommandPill: CGFloat = 6

    // MARK: - Spacing

    static let composerPaddingH: CGFloat = 12
    static let composerPaddingV: CGFloat = 10
    static let bubblePaddingH: CGFloat = 16
    static let bubblePaddingV: CGFloat = 14
    static let messageSpacing: CGFloat = 10
    static let metaBarGap: CGFloat = 8

    // MARK: - Typography

    static let codeFontSize: CGFloat = 11
    static let codeFont: Font = .system(size: 11, design: .monospaced)
    static let bodyFontSize: CGFloat = 14
    static let bodyFont: Font = .system(size: 14)
    static let captionFontSize: CGFloat = 11
    static let metaFontSize: CGFloat = 11

    // MARK: - Motion

    static let durFast: Double = 0.12
    static let durNormal: Double = 0.16
    static let durSlow: Double = 0.22
}

// MARK: - Glassmorphic View Modifiers

extension View {
    /// Applies the standard glassmorphic card style from CodexMonitor
    func chatCard(radius: CGFloat = ChatTokens.radiusCard) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
            )
    }

    /// Applies the tool-call inline card style
    func toolCallCard() -> some View {
        self
            .background(ChatTokens.surfaceCard, in: RoundedRectangle(cornerRadius: ChatTokens.radiusToolCall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatTokens.radiusToolCall, style: .continuous)
                    .strokeBorder(ChatTokens.borderSubtle, lineWidth: 1)
            )
    }

    /// Conditionally apply a modifier
    @ViewBuilder
    func `if`<Modified: View>(_ condition: Bool, transform: (Self) -> Modified) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
