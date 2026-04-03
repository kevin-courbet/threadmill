import AppKit
import QuartzCore
import SwiftUI

enum AnimatedGradientBorderStyle: Equatable {
    case streaming
    case plan
    case focusedIdle
}

struct AnimatedGradientBorder: NSViewRepresentable {
    let style: AnimatedGradientBorderStyle
    var cornerRadius: CGFloat = 18
    var lineWidth: CGFloat = 1.2
    var isFocused: Bool = true

    func makeNSView(context: Context) -> AnimatedGradientBorderNSView {
        let view = AnimatedGradientBorderNSView()
        view.update(style: style, cornerRadius: cornerRadius, lineWidth: lineWidth, isFocused: isFocused)
        return view
    }

    func updateNSView(_ nsView: AnimatedGradientBorderNSView, context: Context) {
        nsView.update(style: style, cornerRadius: cornerRadius, lineWidth: lineWidth, isFocused: isFocused)
    }
}

final class AnimatedGradientBorderNSView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let strokeMaskLayer = CAShapeLayer()
    private let separatorLayer = CAShapeLayer()

    private var currentStyle: AnimatedGradientBorderStyle = .focusedIdle
    private var currentCornerRadius: CGFloat = 18
    private var currentLineWidth: CGFloat = 1.2
    private var isFocused = true
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private nonisolated(unsafe) var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
        installObservers()
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        separatorLayer.frame = bounds
        updateStrokePath()
        CATransaction.commit()
    }

    func update(style: AnimatedGradientBorderStyle, cornerRadius: CGFloat, lineWidth: CGFloat, isFocused: Bool) {
        currentStyle = style
        currentCornerRadius = cornerRadius
        currentLineWidth = lineWidth
        self.isFocused = isFocused
        needsLayout = true
        applyCurrentStyle()
    }

    private func setupLayers() {
        guard let rootLayer = layer else {
            return
        }

        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        strokeMaskLayer.fillColor = nil
        strokeMaskLayer.strokeColor = NSColor.white.cgColor
        strokeMaskLayer.lineCap = .round
        strokeMaskLayer.lineJoin = .round
        strokeMaskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        gradientLayer.mask = strokeMaskLayer

        separatorLayer.fillColor = nil
        separatorLayer.lineCap = .round
        separatorLayer.lineJoin = .round
        separatorLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        rootLayer.addSublayer(gradientLayer)
        rootLayer.addSublayer(separatorLayer)
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
                self.applyCurrentStyle()
            }
        }
    }

    private func updateStrokePath() {
        let inset = currentLineWidth / 2
        let pathRect = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(0, currentCornerRadius - inset)
        let path = CGPath(roundedRect: pathRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        strokeMaskLayer.path = path
        strokeMaskLayer.lineWidth = currentLineWidth
        separatorLayer.path = path
        separatorLayer.lineWidth = 1
    }

    private func applyCurrentStyle() {
        gradientLayer.removeAnimation(forKey: "threadmill.border.rotate")
        gradientLayer.removeAnimation(forKey: "threadmill.border.pulse")
        strokeMaskLayer.removeAnimation(forKey: "threadmill.border.dash")

        switch currentStyle {
        case .streaming:
            gradientLayer.isHidden = true
            separatorLayer.isHidden = false
            separatorLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor

        case .plan:
            separatorLayer.isHidden = true
            gradientLayer.isHidden = false
            gradientLayer.opacity = 1
            strokeMaskLayer.lineDashPattern = [6, 4]
            gradientLayer.colors = [
                NSColor.systemBlue.withAlphaComponent(0.2).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.9).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.3).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.9).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.2).cgColor,
            ]
            if !reduceMotion {
                let dash = CABasicAnimation(keyPath: "lineDashPhase")
                dash.fromValue = 0
                dash.toValue = 10
                dash.duration = 1.2
                dash.repeatCount = .infinity
                dash.timingFunction = CAMediaTimingFunction(name: .linear)
                strokeMaskLayer.add(dash, forKey: "threadmill.border.dash")
            }

        case .focusedIdle:
            gradientLayer.isHidden = true
            separatorLayer.isHidden = !isFocused
            separatorLayer.strokeColor = NSColor.separatorColor.cgColor
        }
    }
}
