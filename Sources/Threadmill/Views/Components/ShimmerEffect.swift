import AppKit
import QuartzCore
import SwiftUI

struct ShimmerEffect: NSViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    let text: String
    var font: NSFont = .systemFont(ofSize: 12, weight: .medium)

    func makeNSView(context: Context) -> ShimmerTextNSView {
        ShimmerTextNSView(text: text, font: font, scenePhase: scenePhase)
    }

    func updateNSView(_ nsView: ShimmerTextNSView, context: Context) {
        nsView.update(text: text, font: font, scenePhase: scenePhase)
    }
}

final class ShimmerTextNSView: NSView {
    private let baseTextLayer = CATextLayer()
    private let shimmerGradientLayer = CAGradientLayer()
    private let shimmerMaskTextLayer = CATextLayer()

    private var text: String
    private var font: NSFont
    private var scenePhase: ScenePhase
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private nonisolated(unsafe) var displayOptionsObserver: NSObjectProtocol?

    init(text: String, font: NSFont, scenePhase: ScenePhase) {
        self.text = text
        self.font = font
        self.scenePhase = scenePhase
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
        installObservers()
        update(text: text, font: font, scenePhase: scenePhase)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let displayOptionsObserver {
            NotificationCenter.default.removeObserver(displayOptionsObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(measured.width), height: ceil(max(measured.height, font.capHeight + 4)))
    }

    override func layout() {
        super.layout()
        updateFrames()
    }

    func update(text: String, font: NSFont, scenePhase: ScenePhase) {
        self.text = text
        self.font = font
        self.scenePhase = scenePhase

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)

        baseTextLayer.string = attributedText
        baseTextLayer.font = font
        baseTextLayer.fontSize = font.pointSize

        shimmerMaskTextLayer.string = attributedText
        shimmerMaskTextLayer.font = font
        shimmerMaskTextLayer.fontSize = font.pointSize

        invalidateIntrinsicContentSize()
        needsLayout = true
        applyShimmerState()
    }

    private func setupLayers() {
        guard let rootLayer = layer else {
            return
        }

        baseTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        baseTextLayer.alignmentMode = .left
        baseTextLayer.truncationMode = .end
        baseTextLayer.isWrapped = false

        shimmerGradientLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        shimmerGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerGradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.84).cgColor,
            NSColor.clear.cgColor,
        ]
        shimmerGradientLayer.locations = [0, 0.5, 1]

        shimmerMaskTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        shimmerMaskTextLayer.alignmentMode = .left
        shimmerMaskTextLayer.truncationMode = .end
        shimmerMaskTextLayer.isWrapped = false
        shimmerGradientLayer.mask = shimmerMaskTextLayer

        rootLayer.addSublayer(baseTextLayer)
        rootLayer.addSublayer(shimmerGradientLayer)
    }

    private func installObservers() {
        displayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.applyShimmerState()
            }
        }
    }

    private func updateFrames() {
        let insetY = max(0, (bounds.height - font.pointSize - 2) / 2)
        let textFrame = CGRect(x: 0, y: insetY, width: bounds.width, height: bounds.height - insetY)
        baseTextLayer.frame = textFrame
        shimmerMaskTextLayer.frame = textFrame
        shimmerGradientLayer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
    }

    private func applyShimmerState() {
        shimmerGradientLayer.removeAnimation(forKey: "threadmill.shimmer")

        if scenePhase == .active, !reduceMotion, bounds.width > 0 {
            // Hide static base text — only the shimmer gradient reveals letters
            baseTextLayer.opacity = 0
            shimmerGradientLayer.isHidden = false

            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = -bounds.width
            animation.toValue = bounds.width
            animation.duration = 2.2
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmerGradientLayer.add(animation, forKey: "threadmill.shimmer")
        } else {
            // Reduce-motion fallback: show static text, hide shimmer
            baseTextLayer.opacity = 1
            shimmerGradientLayer.isHidden = true
        }
    }
}
