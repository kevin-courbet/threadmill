---
updated: 2026-03-07
---

# SwiftUI & AppKit Patterns

Patterns learned the hard way building Threadmill's macOS UI. Follow these to avoid known pitfalls.

---

## DisclosureGroup with Custom Chevron Position

**Problem:** SwiftUI's `DisclosureGroup` places its disclosure indicator on the left. Moving it (e.g. to the right) tempts you to abandon `DisclosureGroup` and use manual `if isExpanded` toggling inside a `List`. This causes **layout jank** — SwiftUI's `List` doesn't get a proper layout pass when content appears/disappears manually, producing overlapping/overflowing intermediate frames that only resolve on the next redraw (e.g. mouse hover).

**Solution:** Keep `DisclosureGroup(isExpanded:)` for native animation support, but use a **custom `DisclosureGroupStyle`** to control layout and hide the default indicator.

```swift
struct RepoSection: View {
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // child content
            ForEach(items) { item in
                ItemRow(item: item)
            }
        } label: {
            header  // your custom label with right-side chevron
        }
        .disclosureGroupStyle(NoIndicatorDisclosureStyle())
    }

    private var header: some View {
        HStack {
            Text("Section Title")
            Spacer()
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
        }
    }
}
```

The custom style suppresses the default indicator and adds smooth animation:

```swift
private struct NoIndicatorDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.14), value: configuration.isExpanded)
    }
}
```

**Why this works:** `DisclosureGroup` tells `List` about the expand/collapse lifecycle. The custom style controls rendering while `List` still gets proper layout notifications. Manual `if isExpanded` without `DisclosureGroup` bypasses this entirely.

**Anti-patterns (do NOT use):**
- `VStack { if isExpanded { content } }` inside a `List` — causes layout jank
- `instantToggleTransaction()` / `Transaction(animation: nil)` — disabling animation doesn't fix layout, makes it worse
- `withAnimation { isExpanded.toggle() }` on manual toggle — animates but `List` still doesn't know about the disclosure lifecycle

---

## Hover States in Sidebar Rows

Native macOS hover feedback on sidebar items. Use `.onHover` with a subtle background change.

```swift
struct SidebarRow: View {
    @State private var isHovered = false

    var body: some View {
        HStack { ... }
            .background(isHovered ? Color.white.opacity(0.05) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
```

Keep opacity low (~0.04–0.06) for dark themes. The `contentShape(Rectangle())` ensures the entire row area is hoverable, not just the text.

---

## Settings Window (Aizen Pattern)

Separate `NSWindow` via a singleton manager — not a SwiftUI `Settings` scene (which has limited customization).

```swift
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var settingsWindow: NSWindow?

    func show(/* dependencies */) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(/* dependencies */)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 650, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil  // release view hierarchy + dependencies
    }
}
```

**Critical:** Always nil out `settingsWindow` in `windowWillClose`. Without this, the window (and its entire SwiftUI view tree capturing AppState etc.) lives forever in the singleton.

Wire `⌘,` via:
```swift
.commands {
    CommandGroup(replacing: .appSettings) {
        Button("Settings...") { SettingsWindowManager.shared.show() }
            .keyboardShortcut(",", modifiers: .command)
    }
}
```

Settings root uses `NavigationSplitView` with sidebar list + detail pane. Detail panes use `Form { }.formStyle(.grouped)`.

---

## Terminal Theming (GhosttyKit)

GhosttyKit has no `ghostty_config_set` API. Inject theme defaults by writing a temp config file and loading it via `ghostty_config_load_file` **before** `ghostty_config_load_default_files` — this way user config overrides our defaults.

```swift
// 1. Write theme defaults to temp file
let themeFile = FileManager.default.temporaryDirectory
    .appendingPathComponent("threadmill")
    .appendingPathComponent("ghostty-default-theme.ghostty")
try themeDefaults.write(to: themeFile, atomically: true, encoding: .utf8)

// 2. Load our defaults first (lowest priority)
ghostty_config_load_file(config, themeFile.path)

// 3. Then load user config (overrides ours)
ghostty_config_load_default_files(config)

// 4. Finalize
ghostty_config_finalize(config)
```
