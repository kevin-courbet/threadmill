import ApplicationServices
import Foundation

@MainActor
final class AXTestClient {
    private let appElement: AXUIElement

    init(pid: pid_t) {
        appElement = AXUIElementCreateApplication(pid)
    }

    func click(identifier: String, timeout: TimeInterval) throws {
        let element = try waitForElement(identifier: identifier, timeout: timeout)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw AXTestError("Failed to click \(identifier): \(result.rawValue)")
        }
    }

    func setText(_ text: String, identifier: String, timeout: TimeInterval) throws {
        let element = try waitForElement(identifier: identifier, timeout: timeout)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        guard result == .success else {
            throw AXTestError("Failed to set text for \(identifier): \(result.rawValue)")
        }
    }

    func keyReturn() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func waitForValueContains(identifier: String, value: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = findElement(identifier: identifier), elementString(element).contains(value) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AXTestError("Timed out waiting for value '\(value)' in \(identifier)")
    }

    func waitForLabel(_ label: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if anyElementContainsText(root: appElement, text: label) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AXTestError("Timed out waiting for label '\(label)'")
    }

    func waitForElement(identifier: String, timeout: TimeInterval) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = findElement(identifier: identifier) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw AXTestError("Timed out waiting for element \(identifier)")
    }

    func value(for identifier: String) -> String? {
        guard let element = findElement(identifier: identifier) else {
            return nil
        }
        return elementString(element)
    }

    private func findElement(identifier: String) -> AXUIElement? {
        findElement(root: appElement, identifier: identifier)
    }

    private func findElement(root: AXUIElement, identifier: String) -> AXUIElement? {
        if axString(root, attribute: kAXIdentifierAttribute as CFString) == identifier {
            return root
        }

        for child in children(of: root) {
            if let found = findElement(root: child, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private func anyElementContainsText(root: AXUIElement, text: String) -> Bool {
        if elementString(root).contains(text) {
            return true
        }

        for child in children(of: root) {
            if anyElementContainsText(root: child, text: text) {
                return true
            }
        }
        return false
    }

    private func elementString(_ element: AXUIElement) -> String {
        let value = axString(element, attribute: kAXValueAttribute as CFString)
        let title = axString(element, attribute: kAXTitleAttribute as CFString)
        let description = axString(element, attribute: kAXDescriptionAttribute as CFString)
        return [value, title, description].compactMap { $0 }.joined(separator: " ")
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private func axString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

struct AXTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
