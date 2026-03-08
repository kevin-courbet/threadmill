import ApplicationServices
import Foundation
import XCTest

final class AXTestClient {
    private let appElement: AXUIElement

    init(pid: pid_t) {
        appElement = AXUIElementCreateApplication(pid)
    }

    func waitForIdentifier(_ identifier: String, timeout: TimeInterval = 10) throws -> AXUIElement {
        try wait(timeout: timeout, description: "Element \(identifier) not found") {
            element(identifier: identifier)
        }
    }

    func waitForTitle(_ title: String, timeout: TimeInterval = 10) throws -> AXUIElement {
        try wait(timeout: timeout, description: "Element with title \(title) not found") {
            element(containingTitle: title)
        }
    }

    func waitUntilMissing(identifier: String, timeout: TimeInterval = 10) throws {
        _ = try wait(timeout: timeout, description: "Element \(identifier) still present") {
            element(identifier: identifier) == nil ? true : nil
        }
    }

    func waitUntilTitleMissing(_ title: String, timeout: TimeInterval = 10) throws {
        _ = try wait(timeout: timeout, description: "Element with title \(title) still present") { () -> Bool? in
            element(containingTitle: title) == nil ? true : nil
        }
    }

    func click(identifier: String, timeout: TimeInterval = 10) throws {
        let target = try waitForIdentifier(identifier, timeout: timeout)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        XCTAssertEqual(result, .success, "Failed to click \(identifier): \(result.rawValue)")
    }

    func clickTitle(_ title: String, timeout: TimeInterval = 10) throws {
        let target = try waitForTitle(title, timeout: timeout)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        XCTAssertEqual(result, .success, "Failed to click title \(title): \(result.rawValue)")
    }

    func setText(_ value: String, identifier: String, timeout: TimeInterval = 10) throws {
        let target = try waitForIdentifier(identifier, timeout: timeout)
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFTypeRef)
        XCTAssertEqual(result, .success, "Failed to set text for \(identifier): \(result.rawValue)")
    }

    func setTextInFirstTextField(_ value: String, timeout: TimeInterval = 10) throws {
        let target = try wait(timeout: timeout, description: "No text field found") {
            firstTextField()
        }
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFTypeRef)
        XCTAssertEqual(result, .success, "Failed to set first text field: \(result.rawValue)")
    }

    func waitForValueContains(identifier: String, value: String, timeout: TimeInterval = 10) throws {
        _ = try wait(timeout: timeout, description: "Value for \(identifier) does not contain \(value)") { () -> Bool? in
            guard let current = stringValue(identifier: identifier) else {
                return nil
            }
            return current.localizedCaseInsensitiveContains(value) ? true : nil
        }
    }

    func waitForAnyValueContains(identifier: String, values: [String], timeout: TimeInterval = 10) throws {
        _ = try wait(timeout: timeout, description: "Value for \(identifier) did not match expected states") { () -> Bool? in
            guard let current = stringValue(identifier: identifier) else {
                return nil
            }
            for value in values where current.localizedCaseInsensitiveContains(value) {
                return true
            }
            return nil
        }
    }

    func findElementWithIdentifierPrefix(_ prefix: String) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return searchByIdentifierPrefix(element: appElement, prefix: prefix, visited: &visited)
    }

    func debugDumpTitles(limit: Int = 200) {
        var visited = Set<UnsafeRawPointer>()
        var lines: [String] = []
        dump(element: appElement, depth: 0, visited: &visited, lines: &lines, limit: limit)
        NSLog("AX-DUMP:\n%@", lines.joined(separator: "\n"))
    }

    private func element(identifier: String) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return search(element: appElement, identifier: identifier, visited: &visited)
    }

    private func element(containingTitle title: String) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return search(element: appElement, containingTitle: title, visited: &visited)
    }

    private func search(element: AXUIElement, identifier: String, visited: inout Set<UnsafeRawPointer>) -> AXUIElement? {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return nil
        }

        if let currentID = attribute(element: element, name: kAXIdentifierAttribute as CFString) as? String,
           currentID == identifier {
            return element
        }

        for child in childElements(of: element) {
            if let found = search(element: child, identifier: identifier, visited: &visited) {
                return found
            }
        }

        return nil
    }

    private func searchByIdentifierPrefix(element: AXUIElement, prefix: String, visited: inout Set<UnsafeRawPointer>) -> AXUIElement? {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return nil
        }

        if let currentID = attribute(element: element, name: kAXIdentifierAttribute as CFString) as? String,
           currentID.hasPrefix(prefix) {
            return element
        }

        for child in childElements(of: element) {
            if let found = searchByIdentifierPrefix(element: child, prefix: prefix, visited: &visited) {
                return found
            }
        }

        return nil
    }

    private func search(element: AXUIElement, containingTitle title: String, visited: inout Set<UnsafeRawPointer>) -> AXUIElement? {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return nil
        }

        if let currentTitle = titleForElement(element),
           currentTitle.localizedCaseInsensitiveContains(title) {
            return element
        }

        for child in childElements(of: element) {
            if let found = search(element: child, containingTitle: title, visited: &visited) {
                return found
            }
        }

        return nil
    }

    private func stringValue(identifier: String) -> String? {
        guard let target = element(identifier: identifier) else {
            return nil
        }

        if let value = attribute(element: target, name: kAXValueAttribute as CFString) as? String {
            return value
        }
        if let title = attribute(element: target, name: kAXTitleAttribute as CFString) as? String {
            return title
        }
        if let description = attribute(element: target, name: kAXDescriptionAttribute as CFString) as? String {
            return description
        }

        var visited = Set<UnsafeRawPointer>()
        let collected = collectText(from: target, visited: &visited)
        return collected.isEmpty ? nil : collected
    }

    private func firstTextField() -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return searchFirstTextField(element: appElement, visited: &visited)
    }

    private func searchFirstTextField(element: AXUIElement, visited: inout Set<UnsafeRawPointer>) -> AXUIElement? {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return nil
        }

        if let role = attribute(element: element, name: kAXRoleAttribute as CFString) as? String,
           role == kAXTextFieldRole as String {
            return element
        }

        for child in childElements(of: element) {
            if let found = searchFirstTextField(element: child, visited: &visited) {
                return found
            }
        }

        return nil
    }

    private func titleForElement(_ element: AXUIElement) -> String? {
        if let title = attribute(element: element, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty {
            return title
        }
        if let value = attribute(element: element, name: kAXValueAttribute as CFString) as? String, !value.isEmpty {
            return value
        }
        if let description = attribute(element: element, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty {
            return description
        }
        return nil
    }

    private func collectText(from element: AXUIElement, visited: inout Set<UnsafeRawPointer>) -> String {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return ""
        }

        var chunks: [String] = []
        if let value = attribute(element: element, name: kAXValueAttribute as CFString) as? String, !value.isEmpty {
            chunks.append(value)
        }
        if let title = attribute(element: element, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty {
            chunks.append(title)
        }
        if let description = attribute(element: element, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty {
            chunks.append(description)
        }

        for child in childElements(of: element) {
            let text = collectText(from: child, visited: &visited)
            if !text.isEmpty {
                chunks.append(text)
            }
        }

        return chunks.joined(separator: " ")
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        let names: [String] = [
            kAXChildrenAttribute as String,
            kAXWindowsAttribute as String,
            kAXRowsAttribute as String,
            kAXTabsAttribute as String,
            kAXContentsAttribute as String,
            kAXVisibleChildrenAttribute as String,
        ]

        var output: [AXUIElement] = []
        for name in names {
            guard let value = attribute(element: element, name: name as CFString) else {
                continue
            }

            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                output.append(value as! AXUIElement)
                continue
            }

            if let items = value as? [AnyObject] {
                for item in items where CFGetTypeID(item) == AXUIElementGetTypeID() {
                    output.append(item as! AXUIElement)
                }
            }
        }
        return output
    }

    private func attribute(element: AXUIElement, name: CFString) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, name, &value)
        guard result == .success else {
            return nil
        }
        return value
    }

    private func wait<T>(timeout: TimeInterval, description: String, body: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(description)
        throw NSError(domain: "ThreadmillUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func dump(
        element: AXUIElement,
        depth: Int,
        visited: inout Set<UnsafeRawPointer>,
        lines: inout [String],
        limit: Int
    ) {
        guard lines.count < limit else {
            return
        }
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else {
            return
        }

        let role = (attribute(element: element, name: kAXRoleAttribute as CFString) as? String) ?? "?"
        let title = titleForElement(element) ?? ""
        lines.append("\(String(repeating: "  ", count: depth))\(role) \(title)")

        for child in childElements(of: element) {
            dump(element: child, depth: depth + 1, visited: &visited, lines: &lines, limit: limit)
        }
    }
}
