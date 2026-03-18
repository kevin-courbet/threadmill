import AppKit
import ApplicationServices
import Foundation

enum DriverError: LocalizedError {
    case usage(String)
    case appNotFound
    case axNotTrusted
    case elementNotFound(String)
    case actionFailed(String, AXError)

    var errorDescription: String? {
        switch self {
        case let .usage(message): return message
        case .appNotFound: return "Threadmill app not found"
        case .axNotTrusted: return "Accessibility access not trusted for threadmill-driver"
        case let .elementNotFound(identifier): return "Element not found: \(identifier)"
        case let .actionFailed(identifier, error): return "Action failed for \(identifier): \(error.rawValue)"
        }
    }
}

final class AXDriver {
    private let appElement: AXUIElement

    init(pid: pid_t) {
        appElement = AXUIElementCreateApplication(pid)
    }

    func stringValue(identifier: String) -> String? {
        guard let target = element(identifier: identifier) else { return nil }
        if let value = attribute(element: target, name: kAXValueAttribute as CFString) as? String, !value.isEmpty { return value }
        if let title = attribute(element: target, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty { return title }
        if let description = attribute(element: target, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty { return description }
        var visited = Set<UnsafeRawPointer>()
        let collected = collectText(from: target, visited: &visited)
        return collected.isEmpty ? nil : collected
    }

    func waitForIdentifier(_ identifier: String, timeout: TimeInterval) -> AXUIElement? {
        wait(timeout: timeout) { self.element(identifier: identifier) }
    }

    func waitForValue(identifier: String, timeout: TimeInterval) -> String? {
        wait(timeout: timeout) { self.stringValue(identifier: identifier) }
    }

    func click(identifier: String, timeout: TimeInterval) throws {
        guard let target = waitForIdentifier(identifier, timeout: timeout) else {
            throw DriverError.elementNotFound(identifier)
        }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else { throw DriverError.actionFailed(identifier, result) }
    }

    func dump(limit: Int = 200) -> String {
        var visited = Set<UnsafeRawPointer>()
        var lines: [String] = []
        dump(element: appElement, depth: 0, visited: &visited, lines: &lines, limit: limit)
        return lines.joined(separator: "\n")
    }

    private func element(identifier: String) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        return search(element: appElement, identifier: identifier, visited: &visited)
    }

    private func search(element: AXUIElement, identifier: String, visited: inout Set<UnsafeRawPointer>) -> AXUIElement? {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else { return nil }
        if let currentID = attribute(element: element, name: kAXIdentifierAttribute as CFString) as? String,
           currentID == identifier {
            return element
        }
        for child in childElements(of: element) {
            if let found = search(element: child, identifier: identifier, visited: &visited) { return found }
        }
        return nil
    }

    private func collectText(from element: AXUIElement, visited: inout Set<UnsafeRawPointer>) -> String {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else { return "" }
        var chunks: [String] = []
        if let value = attribute(element: element, name: kAXValueAttribute as CFString) as? String, !value.isEmpty { chunks.append(value) }
        if let title = attribute(element: element, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty { chunks.append(title) }
        if let description = attribute(element: element, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty { chunks.append(description) }
        for child in childElements(of: element) {
            let text = collectText(from: child, visited: &visited)
            if !text.isEmpty { chunks.append(text) }
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
            guard let value = attribute(element: element, name: name as CFString) else { continue }
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
        guard result == .success else { return nil }
        return value
    }

    private func wait<T>(timeout: TimeInterval, body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func titleForElement(_ element: AXUIElement) -> String? {
        if let title = attribute(element: element, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty { return title }
        if let value = attribute(element: element, name: kAXValueAttribute as CFString) as? String, !value.isEmpty { return value }
        if let description = attribute(element: element, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty { return description }
        return nil
    }

    private func dump(element: AXUIElement, depth: Int, visited: inout Set<UnsafeRawPointer>, lines: inout [String], limit: Int) {
        guard lines.count < limit else { return }
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else { return }
        let role = (attribute(element: element, name: kAXRoleAttribute as CFString) as? String) ?? "<role>"
        let identifier = (attribute(element: element, name: kAXIdentifierAttribute as CFString) as? String) ?? ""
        let title = titleForElement(element) ?? ""
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)role=\(role) id=\(identifier) title=\(title)")
        for child in childElements(of: element) {
            dump(element: child, depth: depth + 1, visited: &visited, lines: &lines, limit: limit)
        }
    }
}

func locateThreadmillPID() -> pid_t? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.xctest")
    _ = apps
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "threadmill.Threadmill").first {
        return app.processIdentifier
    }
    return NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Threadmill" })?.processIdentifier
}

func requireTrustedAccessibility() throws {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw DriverError.axNotTrusted
    }
}

let args = CommandLine.arguments

do {
    try requireTrustedAccessibility()
    guard let pid = locateThreadmillPID() else { throw DriverError.appNotFound }
    let driver = AXDriver(pid: pid)
    guard args.count >= 2 else {
        throw DriverError.usage("usage: threadmill-driver <get|wait|click|dump> <accessibility-id?> [timeout-seconds]")
    }

    let command = args[1]
    let identifier = args.count >= 3 ? args[2] : ""
    let timeout = args.count >= 4 ? TimeInterval(args[3]) ?? 10 : 10

    switch command {
    case "get":
        guard !identifier.isEmpty else { throw DriverError.usage("get requires an accessibility id") }
        if let value = driver.stringValue(identifier: identifier) {
            print(value)
        } else {
            throw DriverError.elementNotFound(identifier)
        }
    case "wait":
        guard !identifier.isEmpty else { throw DriverError.usage("wait requires an accessibility id") }
        if let value = driver.waitForValue(identifier: identifier, timeout: timeout) {
            print(value)
        } else {
            throw DriverError.elementNotFound(identifier)
        }
    case "click":
        guard !identifier.isEmpty else { throw DriverError.usage("click requires an accessibility id") }
        try driver.click(identifier: identifier, timeout: timeout)
    case "dump":
        let limit = args.count >= 3 ? Int(args[2]) ?? 200 : 200
        print(driver.dump(limit: limit))
    default:
        throw DriverError.usage("unknown command: \(command)")
    }
} catch {
    fputs("threadmill-driver: \(error.localizedDescription)\n", stderr)
    exit(1)
}
