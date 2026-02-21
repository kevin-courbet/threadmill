import AppKit
import GhosttyKit

final class GhosttyNSView: NSView {
    var surface: ghostty_surface_t?
    var onSizeChanged: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let layer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width * scale),
            UInt32(bounds.height * scale)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_size(surface, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            onSizeChanged?()
        }
    }

    private var keyTextAccumulator: [String]?

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) {
            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = UInt32(event.keyCode)
            key_ev.mods = modsFromFlags(event.modifierFlags)
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.composing = false
            key_ev.unshifted_codepoint = unshiftedCodepoint(from: event)

            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            } else {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            }
            return
        }

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = modsFromFlags(event.modifierFlags)
        key_ev.consumed_mods = consumedMods(from: event.modifierFlags)
        key_ev.unshifted_codepoint = unshiftedCodepoint(from: event)
        key_ev.composing = false

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        key_ev.text = ptr
                        _ = ghostty_surface_key(surface, key_ev)
                    }
                } else {
                    key_ev.text = nil
                    _ = ghostty_surface_key(surface, key_ev)
                }
            }
        } else {
            let text = textForKeyEvent(event)
            if let text, shouldSendText(text) {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            } else {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key_ev = ghostty_input_key_s()
        key_ev.action = GHOSTTY_ACTION_RELEASE
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.mods = modsFromFlags(event.modifierFlags)
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        key_ev.text = nil
        key_ev.composing = false
        _ = ghostty_surface_key(surface, key_ev)
    }

    override func flagsChanged(with event: NSEvent) {}

    override func insertText(_ string: Any) {
        let str: String
        if let s = string as? String {
            str = s
        } else if let s = string as? NSAttributedString {
            str = s.string
        } else {
            return
        }
        keyTextAccumulator?.append(str)
    }

    override func doCommand(by selector: Selector) {}

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromFlags(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromFlags(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, modsFromFlags(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return chars
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }
}

extension NSScreen {
    var displayID: UInt32? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return id.uint32Value
    }
}
