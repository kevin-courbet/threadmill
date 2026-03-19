import AppKit
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
    let isAddDisabled: Bool

    @State private var scrollViewProxy: ScrollViewProxy?

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                NavigationArrowButton(
                    icon: "chevron.left",
                    isDisabled: previousTabID == nil,
                    help: "Previous tab"
                ) {
                    scrollToPrevious()
                }

                NavigationArrowButton(
                    icon: "chevron.right",
                    isDisabled: nextTabID == nil,
                    help: "Next tab"
                ) {
                    scrollToNext()
                }
            }
            .padding(.leading, 8)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            sessionTab(tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxWidth: 600, maxHeight: 36)
                .onAppear {
                    scrollViewProxy = proxy
                    guard let selectedTabID else { return }
                    proxy.scrollTo(selectedTabID, anchor: .center)
                }
                .onChange(of: selectedTabID) { _, next in
                    guard let next else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(next, anchor: .center)
                    }
                }
                .background(WheelScrollHandler { _ in })
            }

            NewTabButton(
                onAddDefault: onAddDefault,
                addMenuItems: addMenuItems,
                addButtonHelp: addButtonHelp,
                addButtonAccessibilityID: addButtonAccessibilityID,
                isDisabled: isAddDisabled
            )
            .padding(.trailing, 8)
        }
        .frame(maxHeight: 36)
    }

    private func sessionTab(_ tab: SessionTabItem) -> some View {
        SessionTabButton(isSelected: tab.id == selectedTabID) {
            onSelect(tab.id)
        } content: {
            HStack(spacing: 6) {
                if tab.isClosable {
                    SessionCloseButton {
                        onClose(tab.id)
                    }
                    .accessibilityIdentifier("session.tab.close.\(tab.id)")
                }

                if let icon = tab.icon, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                }

                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contextMenu {
            if tab.isClosable {
                Button("Close Tab") {
                    onClose(tab.id)
                }

                if !isFirstTab(tab.id) {
                    Button("Close All to the Left") {
                        onCloseAllLeft(tab.id)
                    }
                }

                if !isLastTab(tab.id) {
                    Button("Close All to the Right") {
                        onCloseAllRight(tab.id)
                    }
                }

                if closableTabCount > 1 {
                    Button("Close Other Tabs") {
                        onCloseOthers(tab.id)
                    }
                }
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

    private var closableTabCount: Int {
        tabs.filter(\.isClosable).count
    }

    private func isFirstTab(_ id: String) -> Bool {
        tabs.first?.id == id
    }

    private func isLastTab(_ id: String) -> Bool {
        tabs.last?.id == id
    }

    private func scrollToPrevious() {
        guard let previousTabID else { return }
        onSelect(previousTabID)
        scrollViewProxy?.scrollTo(previousTabID, anchor: .center)
    }

    private func scrollToNext() {
        guard let nextTabID else { return }
        onSelect(nextTabID)
        scrollViewProxy?.scrollTo(nextTabID, anchor: .center)
    }
}

private struct SessionTabButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let content: Content

    @State private var isHovering = false

    init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    var body: some View {
        // Content is laid out directly (not inside a Button label) so nested
        // buttons (e.g. close) receive their own clicks.
        content
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color(nsColor: .separatorColor)
                    : (isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear),
                in: Capsule()
            )
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .accessibilityRepresentation {
                Button(action: action) {
                    EmptyView()
                }
            }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct SessionCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct NavigationArrowButton: View {
    let icon: String
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var clickTrigger = 0

    var body: some View {
        let button = Button {
            clickTrigger += 1
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .background(
                    isHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help)

        if #available(macOS 14.0, *) {
            button.symbolEffect(.bounce, value: clickTrigger)
        } else {
            button
        }
    }
}

private struct NewTabButton: View {
    let onAddDefault: () -> Void
    let addMenuItems: [SessionAddMenuItem]
    let addButtonHelp: String
    let addButtonAccessibilityID: String
    let isDisabled: Bool

    @State private var isPlusHovering = false
    @State private var isChevronHovering = false
    @State private var clickTrigger = 0

    var body: some View {
        if addMenuItems.isEmpty {
            let button = Button {
                clickTrigger += 1
                onAddDefault()
            } label: {
                plusLabel
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.35 : 1)
            .onHover { hovering in
                isPlusHovering = hovering
            }
            .help(addButtonHelp)
            .accessibilityIdentifier(addButtonAccessibilityID)

            if #available(macOS 14.0, *) {
                button.symbolEffect(.bounce, value: clickTrigger)
            } else {
                button
            }
        } else {
            HStack(spacing: 2) {
                let plusButton = Button {
                    clickTrigger += 1
                    onAddDefault()
                } label: {
                    plusLabel
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.35 : 1)
                .onHover { hovering in
                    isPlusHovering = hovering
                }
                .help(addButtonHelp)
                .accessibilityIdentifier(addButtonAccessibilityID)

                if #available(macOS 14.0, *) {
                    plusButton.symbolEffect(.bounce, value: clickTrigger)
                } else {
                    plusButton
                }

                Menu {
                    ForEach(addMenuItems) { item in
                        Button(item.title, action: item.action)
                    }
                } label: {
                    chevronLabel
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .onHover { hovering in
                    isChevronHovering = hovering
                }
                .help(addButtonHelp)
                .accessibilityIdentifier("\(addButtonAccessibilityID).menu")
            }
            .padding(.leading, 1)
            .padding(.trailing, 1)
        }
    }

    private var chevronLabel: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 16, height: 24)
            .background(
                isChevronHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private var plusLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 11))
            .frame(width: 24, height: 24)
            .background(
                isPlusHovering ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                in: Circle()
            )
    }
}

private struct WheelScrollHandler: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelScrollView {
        let view = WheelScrollView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: WheelScrollView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class WheelScrollView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                onScroll?(event.scrollingDeltaY)
            }
            super.scrollWheel(with: event)
        }
    }
}
