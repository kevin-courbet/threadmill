---
updated: 2026-03-29
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

## @Observable + @State: The Rules

iOS 17+ replaced `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject` with `@Observable`. The new model is simpler but has critical rules. Violating them causes **silent observation failures** — views render once and never update, with no warnings or errors.

### The mental model

With `@Observable`, SwiftUI tracks **which specific properties** each view reads during body evaluation and re-renders **only that view** when **those specific properties** change. This is property-level tracking (not object-level like `ObservableObject` was).

### The rules

| View role | Wrapper | Example |
|---|---|---|
| **Owner** (creates the model) | `@State private var` | `@State private var vm = MyViewModel()` |
| **Consumer** (receives the model) | Plain `let` or `var` | `let vm: MyViewModel` |
| **Needs two-way binding** ($) | `@Bindable var` | `@Bindable var vm: MyViewModel` (for TextField, Toggle, etc.) |
| **Shared via environment** | `@Environment` | `@Environment(MyViewModel.self) private var vm` |

### BANNED: @State on a received @Observable

```swift
// BROKEN — observation silently fails
struct ChatSessionView: View {
    @State var viewModel: ChatSessionViewModel  // ← NEVER do this
    var body: some View {
        // viewModel.channelID changes → this body NEVER re-runs
        ChatInputBar(viewModel: viewModel)
    }
}

// CORRECT — plain var, observation works
struct ChatSessionView: View {
    var viewModel: ChatSessionViewModel  // ← just a var
    var body: some View {
        ChatInputBar(viewModel: viewModel)  // re-renders on property changes
    }
}
```

**Why it breaks:** `@State` caches the value across view struct recreations. For reference types, it preserves the identity (same pointer). But internally, `@State`'s storage wrapper interferes with `@Observable`'s property access tracking — SwiftUI doesn't register the property reads that happen through `@State`'s wrapped value, so it never schedules re-renders when those properties change.

**Why it's silent:** The view renders once with initial values. No crash, no warning, no error. Properties change but the body never re-evaluates. You only discover it by adding logging inside computed properties and seeing they're never called again.

### @State IS correct for the owner

The view that **creates** the model uses `@State` — this is correct and necessary:

```swift
// App-level or root view: @State creates and owns the model
struct ContentView: View {
    @State private var vm = ChatSessionViewModel()  // ← owner, correct

    var body: some View {
        ChatSessionView(viewModel: vm)  // passes to child as plain var
    }
}
```

`@State` here ensures the model is created once and persists across view rebuilds. Observation works because SwiftUI tracks property access when the model is read through child views (which hold it as plain `var`/`let`).

### @State init gotcha: phantom instances

Unlike `@StateObject` (which used `@autoclosure` for lazy init), `@State`'s initializer eagerly evaluates its argument. This means **every time SwiftUI rebuilds the view struct**, it creates a new instance of your model, then immediately discards it and restores the cached original.

```swift
@State private var vm = ExpensiveViewModel()
// ExpensiveViewModel.init() runs on EVERY parent rebuild
// SwiftUI throws away the new instance and keeps the original
// Side effects in init() (network calls, timers, observers) stack up
```

**Fix:** Keep `init()` side-effect-free. Move setup to `.task {}`:

```swift
struct RootView: View {
    @State private var vm = MyViewModel()

    var body: some View {
        ContentView(vm: vm)
            .task { vm.setup() }  // runs once when view appears
    }
}
```

### Summary cheat sheet

```
Owner creates model     → @State private var vm = Model()
Child receives model    → let vm: Model  (or var vm: Model)
Child needs $ bindings  → @Bindable var vm: Model
Deep injection          → .environment(vm) + @Environment(Model.self)
Combine streams         → still use Combine (it's not replaced)
```

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
