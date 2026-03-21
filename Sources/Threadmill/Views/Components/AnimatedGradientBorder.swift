import AppKit
import QuartzCore
import SwiftUI

enum AnimatedGradientBorderState {
    case streaming
    case plan
    case idleFocused
}

struct AnimatedGradientBorder: NSViewRepresentable {
    let state: AnimatedGradientBorderState
    var cornerRadius: CGFloat = 18
    var lineWidth: CGFloat = 1.2

    func makeNSView(context: Context) -> GradientBorderNSView {
        GradientBorderNSView(state: state, cornerRadius: cornerRadius, lineWidth: lineWidth)
    }

    func updateNSView(_ nsView: GradientBorderNSView, context: Context) {
        nsView.update(state: state, cornerRadius: cornerRadius, lineWidth: lineWidth)
    }
}

final class GradientBorderNSView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private let fallbackBorderLayer = CAShapeLayer()
    private var state: AnimatedGradientBorderState
    private var cornerRadius: CGFloat
    private var lineWidth: CGFloat
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var displayOptionsObserver: NSObjectProtocol?

    init(state: AnimatedGradientBorderState, cornerRadius: CGFloat, lineWidth: CGFloat) {
        self.state = state
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
        installObservers()
        applyStyle(animated: false)
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
        gradientLayer.frame = bounds
        fallbackBorderLayer.frame = bounds
        updatePaths()
    }

    func update(state: AnimatedGradientBorderState, cornerRadius: CGFloat, lineWidth: CGFloat) {
        let previousReduceMotion = reduceMotion
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let didChange = self.state != state || self.cornerRadius != cornerRadius || self.lineWidth != lineWidth || previousReduceMotion != reduceMotion
        self.state = state
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        updatePaths()

        if didChange {
            applyStyle(animated: true)
        }
    }

    private func setupLayers() {
        guard let rootLayer = layer else {
            return
        }

        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradientLayer.mask = gradientMask

        gradientMask.fillColor = nil
        gradientMask.strokeColor = NSColor.white.cgColor

        fallbackBorderLayer.fillColor = nil

        rootLayer.addSublayer(gradientLayer)
        rootLayer.addSublayer(fallbackBorderLayer)
    }

    private func installObservers() {
        displayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.applyStyle(animated: true)
        }
    }

    private func updatePaths() {
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).cgPath

        gradientMask.path = path
        gradientMask.lineWidth = lineWidth
        fallbackBorderLayer.path = path
        fallbackBorderLayer.lineWidth = lineWidth
    }

    private func applyStyle(animated: Bool) {
        gradientLayer.removeAllAnimations()
        gradientMask.removeAllAnimations()
        fallbackBorderLayer.removeAllAnimations()

        switch state {
        case .streaming:
            fallbackBorderLayer.isHidden = true
            gradientLayer.isHidden = false
            gradientLayer.colors = [
                NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor,
                NSColor.systemPink.withAlphaComponent(0.75).cgColor,
                NSColor.systemTeal.withAlphaComponent(0.8).cgColor,
                NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor,
            ]

            guard animated, !reduceMotion else {
                return
            }

            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 3.4
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            gradientLayer.add(rotation, forKey: "threadmill.border.rotate")

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.65
            pulse.toValue = 1.0
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradientMask.add(pulse, forKey: "threadmill.border.opacity")

        case .plan:
            gradientLayer.isHidden = true
            fallbackBorderLayer.isHidden = false
            fallbackBorderLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            fallbackBorderLayer.lineDashPattern = [6, 4]

        case .idleFocused:
            gradientLayer.isHidden = true
            fallbackBorderLayer.isHidden = false
            fallbackBorderLayer.strokeColor = NSColor.separatorColor.cgColor
            fallbackBorderLayer.lineDashPattern = nil
        }
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0 ..< elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                continue
            }
        }

        return path
    }
}
