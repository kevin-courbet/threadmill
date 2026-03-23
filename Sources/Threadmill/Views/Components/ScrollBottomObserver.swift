import AppKit
import SwiftUI

struct ScrollBottomObserver: NSViewRepresentable {
    let onNearBottomChange: (Bool) -> Void
    let onUserScrolledUpChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNearBottomChange: onNearBottomChange, onUserScrolledUpChange: onUserScrolledUpChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.scheduleAttach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNearBottomChange = onNearBottomChange
        context.coordinator.onUserScrolledUpChange = onUserScrolledUpChange
        context.coordinator.scheduleAttach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var onNearBottomChange: (Bool) -> Void
        var onUserScrolledUpChange: (Bool) -> Void

        private weak var scrollView: NSScrollView?
        private var boundsObservation: NSObjectProtocol?
        private var frameObservation: NSObjectProtocol?

        private var isNearBottom = true
        private var userScrolledUp = false

        private let enterThreshold: CGFloat = 24.5
        private let leaveThreshold: CGFloat = 36

        init(
            onNearBottomChange: @escaping (Bool) -> Void,
            onUserScrolledUpChange: @escaping (Bool) -> Void
        ) {
            self.onNearBottomChange = onNearBottomChange
            self.onUserScrolledUpChange = onUserScrolledUpChange
        }

        func scheduleAttach(to view: NSView) {
            if let scrollView = resolveScrollView(from: view) {
                attach(to: scrollView)
                return
            }

            // Delay to next run loop iteration — the scroll view may not be
            // in the hierarchy yet on first layout pass.
            DispatchQueue.main.async {
                guard let scrollView = self.resolveScrollView(from: view) else {
                    return
                }
                self.attach(to: scrollView)
            }
        }

        func detach() {
            if let obs = boundsObservation { NotificationCenter.default.removeObserver(obs) }
            if let obs = frameObservation { NotificationCenter.default.removeObserver(obs) }
            boundsObservation = nil
            frameObservation = nil
            scrollView = nil
        }

        private func attach(to scrollView: NSScrollView) {
            guard self.scrollView !== scrollView else {
                evaluatePosition()
                return
            }

            detach()
            self.scrollView = scrollView

            let contentView = scrollView.contentView
            boundsObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                self?.evaluatePosition()
            }
            contentView.postsBoundsChangedNotifications = true

            if let documentView = scrollView.documentView {
                frameObservation = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.evaluatePosition()
                }
                documentView.postsFrameChangedNotifications = true
            }

            evaluatePosition()
        }

        private func evaluatePosition() {
            guard let scrollView, let documentView = scrollView.documentView else {
                return
            }

            let visibleRect = documentView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
            let distanceToBottom: CGFloat
            if documentView.isFlipped {
                distanceToBottom = max(documentView.bounds.maxY - visibleRect.maxY, 0)
            } else {
                distanceToBottom = max(visibleRect.minY - documentView.bounds.minY, 0)
            }

            let nextNearBottom: Bool
            if isNearBottom {
                nextNearBottom = distanceToBottom <= leaveThreshold
            } else {
                nextNearBottom = distanceToBottom <= enterThreshold
            }

            if nextNearBottom != isNearBottom {
                isNearBottom = nextNearBottom
                onNearBottomChange(nextNearBottom)
            }

            let nextUserScrolledUp = !nextNearBottom
            if nextUserScrolledUp != userScrolledUp {
                userScrolledUp = nextUserScrolledUp
                onUserScrolledUpChange(nextUserScrolledUp)
            }
        }

        private func resolveScrollView(from view: NSView) -> NSScrollView? {
            if let enclosing = view.enclosingScrollView {
                return enclosing
            }

            var node: NSView? = view
            while let current = node {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                node = current.superview
            }
            return nil
        }
    }
}
