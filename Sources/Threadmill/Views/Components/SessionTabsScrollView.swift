import SwiftUI

struct SessionTabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String?
    let isClosable: Bool

    init(id: String, title: String, icon: String? = nil, isClosable: Bool = true) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isClosable = isClosable
    }
}

struct SessionAddMenuItem: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

struct SessionTabsScrollView: View {
    let tabs: [SessionTabItem]
    let selectedTabID: String?
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onCloseAllLeft: (String) -> Void
    let onCloseAllRight: (String) -> Void
    let onCloseOthers: (String) -> Void
    let onAddDefault: () -> Void
    let addMenuItems: [SessionAddMenuItem]
    let addButtonHelp: String
    let addButtonAccessibilityID: String

    @State private var hoveredTabID: String?

    var body: some View {
        HStack(spacing: 6) {
            NavigationArrowButton(systemImage: "chevron.left", isDisabled: previousTabID == nil) {
                guard let previousTabID else { return }
                onSelect(previousTabID)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            sessionTab(tab)
                                .id(tab.id)
                        }
                    }
                }
                .onAppear {
                    guard let selectedTabID else { return }
                    proxy.scrollTo(selectedTabID, anchor: .center)
                }
                .onChange(of: selectedTabID) { _, next in
                    guard let next else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(next, anchor: .center)
                    }
                }
            }

            NavigationArrowButton(systemImage: "chevron.right", isDisabled: nextTabID == nil) {
                guard let nextTabID else { return }
                onSelect(nextTabID)
            }

            Menu {
                if addMenuItems.isEmpty {
                    Button("New Session", action: onAddDefault)
                } else {
                    ForEach(addMenuItems) { item in
                        Button(item.title, action: item.action)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            } primaryAction: {
                onAddDefault()
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help(addButtonHelp)
            .accessibilityIdentifier(addButtonAccessibilityID)
        }
        .frame(height: 30)
    }

    private func sessionTab(_ tab: SessionTabItem) -> some View {
        let isSelected = tab.id == selectedTabID
        let isCloseVisible = tab.isClosable && (isSelected || hoveredTabID == tab.id)

        return TabContainer(isSelected: isSelected) {
            onSelect(tab.id)
        } content: {
            HStack(spacing: 6) {
                TabLabel(title: tab.title, icon: tab.icon)

                TabCloseButton {
                    onClose(tab.id)
                }
                .opacity(isCloseVisible ? 1 : 0)
                .allowsHitTesting(isCloseVisible)
                .accessibilityHidden(!tab.isClosable)
            }
        }
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : nil
        }
        .contextMenu {
            if tab.isClosable {
                Button("Close") {
                    onClose(tab.id)
                }

                Divider()

                Button("Close All Left") {
                    onCloseAllLeft(tab.id)
                }
                .disabled(!canCloseLeft(of: tab.id))

                Button("Close All Right") {
                    onCloseAllRight(tab.id)
                }
                .disabled(!canCloseRight(of: tab.id))

                Button("Close Others") {
                    onCloseOthers(tab.id)
                }
                .disabled(!canCloseOthers(of: tab.id))
            }
        }
        .accessibilityIdentifier("session.tab.\(tab.id)")
    }

    private var selectedIndex: Int? {
        guard let selectedTabID else {
            return nil
        }
        return tabs.firstIndex(where: { $0.id == selectedTabID })
    }

    private var previousTabID: String? {
        guard let selectedIndex, selectedIndex > 0 else {
            return nil
        }
        return tabs[selectedIndex - 1].id
    }

    private var nextTabID: String? {
        guard let selectedIndex, selectedIndex + 1 < tabs.count else {
            return nil
        }
        return tabs[selectedIndex + 1].id
    }

    private func canCloseLeft(of id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return tabs[..<index].contains(where: { $0.isClosable })
    }

    private func canCloseRight(of id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard index + 1 < tabs.count else {
            return false
        }
        return tabs[(index + 1)...].contains(where: { $0.isClosable })
    }

    private func canCloseOthers(of id: String) -> Bool {
        tabs.contains(where: { $0.id != id && $0.isClosable })
    }
}

private struct NavigationArrowButton: View {
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }
}
