import SwiftUI

/// Provider icons using custom SF Symbols from aizen's asset catalog.
struct ProviderGlyph: View {
    let harness: ChatHarness
    let size: CGFloat

    var body: some View {
        ZStack {
            // Radial glow halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(0.15), accentColor.opacity(0.0)],
                        center: .center,
                        startRadius: size * 0.2,
                        endRadius: size * 0.5
                    )
                )
                .frame(width: size, height: size)

            // Glass backing
            Circle()
                .fill(accentColor.opacity(0.06))
                .frame(width: size * 0.75, height: size * 0.75)
                .overlay(
                    Circle()
                        .strokeBorder(accentColor.opacity(0.2), lineWidth: 1.5)
                )

            // Custom SF Symbol — try bundle resources, fall back to SF Symbols
            providerImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.38, height: size * 0.38)
                .foregroundStyle(accentColor)
        }
    }

    private var providerImage: Image {
        // Try loading custom SF Symbol from our asset catalog in the resource bundle
        let img = Image(symbolName, bundle: Bundle.module)
        // Image(_:bundle:) doesn't fail visibly — but if the symbol didn't load,
        // the view renders empty. We try both bundle and main, then fall back.
        if NSImage(named: symbolName) != nil {
            return Image(nsImage: NSImage(named: symbolName)!)
        }
        // Try the resource bundle symbol image (available macOS 14+)
        if let nsImg = NSImage(symbolName: symbolName, bundle: Bundle.module, variableValue: 1.0) {
            return Image(nsImage: nsImg)
        }
        // Last resort: system SF Symbol
        return Image(systemName: fallbackSystemName)
    }

    private var symbolName: String {
        switch harness {
        case .opencode: return "opencode"
        case .claude: return "claude"
        case .codex: return "openai"
        case .gemini: return "gemini"
        }
    }

    private var fallbackSystemName: String {
        switch harness {
        case .opencode: return "terminal.fill"
        case .claude: return "sun.max.fill"
        case .codex: return "hexagon.fill"
        case .gemini: return "sparkles"
        }
    }

    private var accentColor: Color {
        switch harness {
        case .opencode: return Color(hue: 0.53, saturation: 0.7, brightness: 0.95)
        case .claude: return Color(hue: 0.06, saturation: 0.8, brightness: 0.95)
        case .codex: return Color(hue: 0.38, saturation: 0.7, brightness: 0.88)
        case .gemini: return Color(hue: 0.6, saturation: 0.6, brightness: 0.95)
        }
    }
}
