import AppKit
import ApplicationServices
import Foundation

let debugArtifactsDirectory = URL(fileURLWithPath: "/tmp/threadmill-debug", isDirectory: true)

enum DriverError: LocalizedError {
    case usage(String)
    case appNotFound
    case axNotTrusted
    case debugArtifactNotFound(String)
    case elementNotFound(String)
    case actionFailed(String, AXError)
    case keyUsage

    var errorDescription: String? {
        switch self {
        case let .usage(message): return message
        case .appNotFound: return "Threadmill app not found"
        case .axNotTrusted: return "Accessibility access not trusted for threadmill-driver"
        case let .debugArtifactNotFound(name): return "Debug artifact not found: \(name)"
        case let .elementNotFound(identifier): return "Element not found: \(identifier)"
        case let .actionFailed(identifier, error): return "Action failed for \(identifier): \(error.rawValue)"
        case .keyUsage: return "key command expects a key and optional modifiers like cmd,shift,ctrl,option"
        }
    }
}

final class AXDriver {
    private let pid: pid_t
    private let appElement: AXUIElement

    init(pid: pid_t) {
        self.pid = pid
        appElement = AXUIElementCreateApplication(pid)
    }

    func activate() {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
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
        guard let target = wait(timeout: timeout, body: { self.actionableElement(identifier: identifier) }) else {
            throw DriverError.elementNotFound(identifier)
        }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result == .success {
            return
        }
        try clickViaFrame(target, identifier: identifier)
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

    private func actionableElement(identifier: String) -> AXUIElement? {
        var visited = Set<UnsafeRawPointer>()
        var matches: [AXUIElement] = []
        collectMatches(element: appElement, identifier: identifier, visited: &visited, matches: &matches)
        return matches.first(where: { isActionable($0) }) ?? matches.first
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

    private func collectMatches(element: AXUIElement, identifier: String, visited: inout Set<UnsafeRawPointer>, matches: inout [AXUIElement]) {
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(element).toOpaque())
        guard visited.insert(pointer).inserted else { return }
        if let currentID = attribute(element: element, name: kAXIdentifierAttribute as CFString) as? String,
           currentID == identifier {
            matches.append(element)
        }
        for child in childElements(of: element) {
            collectMatches(element: child, identifier: identifier, visited: &visited, matches: &matches)
        }
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

    private func clickViaFrame(_ element: AXUIElement, identifier: String) throws {
        guard let center = centerPoint(of: element) else {
            throw DriverError.actionFailed(identifier, .cannotComplete)
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func centerPoint(of element: AXUIElement) -> CGPoint? {
        guard let positionValue = attribute(element: element, name: kAXPositionAttribute as CFString),
              let sizeValue = attribute(element: element, name: kAXSizeAttribute as CFString)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue as! AXValue) == .cgPoint,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetType(sizeValue as! AXValue) == .cgSize,
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func titleForElement(_ element: AXUIElement) -> String? {
        if let title = attribute(element: element, name: kAXTitleAttribute as CFString) as? String, !title.isEmpty { return title }
        if let value = attribute(element: element, name: kAXValueAttribute as CFString) as? String, !value.isEmpty { return value }
        if let description = attribute(element: element, name: kAXDescriptionAttribute as CFString) as? String, !description.isEmpty { return description }
        return nil
    }

    private func isActionable(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element: element, name: kAXRoleAttribute as CFString) as? String else {
            return false
        }
        return role == kAXButtonRole as String || role == kAXRowRole as String || role == kAXTabGroupRole as String
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
        throw DriverError.usage("usage: threadmill-driver <get|wait|click|dump|debug|key|activate> <arg> [extra]")
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
    case "debug":
        guard !identifier.isEmpty else { throw DriverError.usage("debug requires an artifact name") }
        let url = debugArtifactsDirectory.appendingPathComponent("\(identifier).json")
        guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
            throw DriverError.debugArtifactNotFound(identifier)
        }
        print(string)
    case "activate":
        driver.activate()
    case "key":
        guard !identifier.isEmpty else { throw DriverError.keyUsage }
        let modifiers = args.count >= 4 ? args[3].split(separator: ",").map(String.init) : []
        try sendKey(identifier, modifiers: modifiers)
    default:
        throw DriverError.usage("unknown command: \(command)")
    }
} catch {
    fputs("threadmill-driver: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func sendKey(_ key: String, modifiers: [String]) throws {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let keyCode = keyCode(for: key) else { throw DriverError.keyUsage }
    let flags = eventFlags(for: modifiers)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func eventFlags(for modifiers: [String]) -> CGEventFlags {
    modifiers.reduce(into: CGEventFlags()) { flags, modifier in
        switch modifier.lowercased() {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl", "control": flags.insert(.maskControl)
        case "option", "alt": flags.insert(.maskAlternate)
        default: break
        }
    }
}

func keyCode(for key: String) -> CGKeyCode? {
    switch key.lowercased() {
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "t": return 17
    case "w": return 13
    case "r": return 15
    case "k": return 40
    case "tab": return 48
    default: return nil
    }
}
