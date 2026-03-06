---
updated: 2026-03-07
---

# SwiftUI & AppKit Patterns

Patterns learned the hard way building Threadmill's macOS UI. Follow these to avoid known pitfalls.

---

## Collapsible Sections with Custom Chevron Position

**Problem:** SwiftUI's default disclosure indicators (in `DisclosureGroup`, `Section`, `List`) place the chevron on the left. Moving it (e.g. to the right side, next to a + button) is a common design requirement but easily breaks layout.

### What DOESN'T work (and why)

**Manual `if isExpanded` in a VStack inside List** — List doesn't know content changed. Produces overlapping/overflowing intermediate frames that only resolve on mouse hover (triggering a redraw).

**`DisclosureGroup` + custom `DisclosureGroupStyle`** — Seems right but ALSO causes the same jank. The custom style's `makeBody` still uses `if configuration.isExpanded` inside a VStack, which bypasses List's layout engine just like manual toggling. The DisclosureGroup wrapper provides the state binding but the custom style defeats the layout integration that makes it smooth.

**`instantToggleTransaction()` / `Transaction(animation: nil)`** — Disabling animation doesn't fix layout, makes it worse.

### What WORKS: `Section(isExpanded:)` (macOS 14+)

`Section(isExpanded:)` is the only approach that gives List full control over the expand/collapse lifecycle AND lets you customize the header freely. Each child row is a proper List row (not nested in a single DisclosureGroup cell), so List can animate them individually.

```swift
struct RepoSection: View {
    @State private var isExpanded = true

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(items) { item in
                ItemRow(item: item)
            }
        } header: {
            HStack {
                Text("Section Title")
                Spacer()

                Button { /* add action */ } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

**Why this works:** `Section(isExpanded:)` tells `List` about the section's collapse state at the layout level. List manages row insertion/removal natively. The header is fully custom — put the chevron anywhere.

**Key details:**
- Wrap `isExpanded.toggle()` in `withAnimation` for smooth content transition
- Use `rotationEffect` on a fixed `chevron.right` icon (not swapping between `chevron.down`/`chevron.right`) for smooth rotation animation
- Works with `.listStyle(.plain)` and `.listStyle(.sidebar)`

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
