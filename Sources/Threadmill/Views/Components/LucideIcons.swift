import AppKit
import SwiftUI

/// Lucide icons rendered from embedded SVG data.
/// ISC License (lucide-icons/lucide v0.577.0)
enum LucideIcon {
    static let pinSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
        fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        <path d="M12 17v5"/>\
        <path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12\
        a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 \
        2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/></svg>
        """

    static let pinOffSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
        fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
        <path d="M12 17v5"/>\
        <path d="M15 9.34V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H7.89"/>\
        <path d="m2 2 20 20"/>\
        <path d="M9 9v1.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h11"/>\
        </svg>
        """

    /// Template NSImage from SVG string data — tintable via `.foregroundStyle()`.
    static func image(from svg: String) -> NSImage? {
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.isTemplate = true
        return image
    }

    static var pin: NSImage? { image(from: pinSVG) }
    static var pinOff: NSImage? { image(from: pinOffSVG) }
}

/// SwiftUI view for rendering a Lucide icon with tinting support.
struct LucideIconView: View {
    let icon: NSImage?
    let size: CGFloat

    init(_ icon: NSImage?, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        }
    }
}
