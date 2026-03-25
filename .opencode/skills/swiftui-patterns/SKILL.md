---
name: swiftui-patterns
description: Best practices and example-driven guidance for building SwiftUI views and components. Use when creating or modifying SwiftUI views in Threadmill.
---

# SwiftUI UI Patterns

Based on dimillian's SwiftUI patterns. For Threadmill-specific patterns (DisclosureGroup, hover states, GhosttyKit theming), see `docs/agents/swiftui-patterns.md`.

## Quick start

- Identify the feature or screen and the primary interaction model (list, detail, editor, settings, tabbed).
- Find a nearby example in the repo with `rg "TabView\("` or similar, then read the closest SwiftUI view.
- Apply local conventions: prefer SwiftUI-native state, keep state local when possible, and use environment injection for shared dependencies.
- Build the view with small, focused subviews and SwiftUI-native data flow.

## General rules

- Use modern SwiftUI state (`@State`, `@Binding`, `@Observable`, `@Environment`) and avoid unnecessary view models.
- Prefer composition; keep views small and focused.
- Use async/await with `.task` and explicit loading/error states.
- Maintain existing legacy patterns only when editing legacy files.
- Follow the project's formatter and style guide.
- **Sheets**: Prefer `.sheet(item:)` over `.sheet(isPresented:)` when state represents a selected model. Avoid `if let` inside a sheet body. Sheets should own their actions and call `dismiss()` internally instead of forwarding `onCancel`/`onConfirm` closures.

**Threadmill exception:** Threadmill uses ViewModels for complex async coordination (`ChatSessionViewModel`, `FileBrowserViewModel`). This is intentional for components with heavy async state machines, WebSocket streaming, and multi-source data. Don't refactor these to pure `@State`.

## Workflow for a new SwiftUI view

1. Define the view's state and its ownership location.
2. Identify dependencies to inject via `@Environment`.
3. Sketch the view hierarchy and extract repeated parts into subviews.
4. Implement async loading with `.task` and explicit state enum if needed.
5. Add accessibility labels or identifiers when the UI is interactive.
6. Validate with a build and update usage callsites if needed.

## Sheet patterns

### Item-driven sheet (preferred)

```swift
@State private var selectedItem: Item?

.sheet(item: $selectedItem) { item in
    EditItemSheet(item: item)
}
```

### Sheet owns its actions

```swift
struct EditItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store

    let item: Item
    @State private var isSaving = false

    var body: some View {
        VStack {
            Button(isSaving ? "Saving..." : "Save") {
                Task { await save() }
            }
        }
    }

    private func save() async {
        isSaving = true
        await store.save(item)
        dismiss()
    }
}
```
