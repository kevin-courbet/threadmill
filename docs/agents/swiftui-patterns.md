---
updated: 2026-03-07
---

# SwiftUI & AppKit Patterns

Patterns learned the hard way building Threadmill's macOS UI. Follow these to avoid known pitfalls.

---

## Collapsible Sections with Custom Chevron Position

**Problem:** SwiftUI's default disclosure indicators (in `DisclosureGroup`, `Section`, `List`) place the chevron on the left. Moving it (e.g. to the right side, next to a + button) is a common design requirement but easily breaks layout.

### What DOESN'T work (and why)

1. **Manual `if isExpanded` in a VStack inside List** — List doesn't know content changed. Produces overlapping/overflowing intermediate frames that only resolve on mouse hover (triggering a redraw).

2. **`DisclosureGroup` + custom `DisclosureGroupStyle`** — The custom style's `makeBody` still uses `if configuration.isExpanded` inside a VStack, which bypasses List's layout engine. Same jank as #1.

3. **`Section(isExpanded:)` with custom header** — Smooth animations, but the Section header gets an **unsuppressible divider line** on macOS `.listStyle(.plain)`. No combination of `.listSectionSeparator(.hidden)`, `.listSectionSeparatorTint(.clear)`, or `.listRowSeparator(.hidden)` on the header removes it. This is a macOS SwiftUI bug/limitation.

4. **`instantToggleTransaction()` / `Transaction(animation: nil)`** — Disabling animation doesn't fix layout, makes it worse.

5. **Multiple `ForEach` blocks in a `List`** — macOS List inserts implicit section boundaries between consecutive `ForEach` blocks, creating phantom dividers that can't be suppressed.

### What WORKS: Flat rows with `if isExpanded` + `withAnimation`

Emit the header and child rows as **flat, independent List rows**. No `Section`, no `DisclosureGroup`. The view's `body` returns multiple rows via `@ViewBuilder`. Wrap `isExpanded.toggle()` in `withAnimation` so List animates row insertion/removal natively.

```swift
struct RepoSection: View {
    let items: [Item]
    @State private var isExpanded = true
    @State private var isHeaderHovered = false

    var body: some View {
        // Header is a regular list row
        header
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            .listRowBackground(Color.clear)

        // Children appear/disappear with animation
        if isExpanded {
            ForEach(items) { item in
                ItemRow(item: item)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Section Title")
            Spacer()
            Button { /* add */ } label: {
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
        .background(isHeaderHovered ? Color.white.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHeaderHovered = $0 }
    }
}
```

**Why this works:** Each row is a direct child of the List's ForEach. The `withAnimation` block tells SwiftUI to animate the `if isExpanded` change, and List handles row insertion/removal with its native animation. No Section header = no phantom divider. No VStack wrapping = no layout jank.

**Key details:**
- Use `rotationEffect` on a fixed `chevron.right` (not swapping icons) for smooth rotation
- Each row must have its own `.listRowSeparator(.hidden)` + `.listRowInsets` + `.listRowBackground`
- If mixing repos and projects, use a **single `ForEach`** over a unified enum to avoid implicit section boundaries:

```swift
private enum SidebarItem: Identifiable {
    case repo(Repo, [Thread])
    case project(Project, [Thread])
    var id: String { /* unique per case */ }
}

List {
    ForEach(sidebarItems) { item in
        switch item {
        case .repo(let r, let t): RepoSection(repo: r, threads: t, ...)
        case .project(let p, let t): ProjectSection(project: p, threads: t, ...)
        }
    }
}
```

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
