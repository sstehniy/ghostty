import AppKit
import SwiftUI

/// Actions the tab sidebar can request. Implemented by the terminal controller that
/// hosts the sidebar; each action names the target tab's window explicitly so that
/// inactive tabs can be targeted.
protocol TerminalTabSidebarActions: AnyObject {
    func sidebarSelect(_ window: NSWindow)
    func sidebarNewTab()
    func sidebarClose(_ window: NSWindow)
    func sidebarCloseOthers(_ window: NSWindow)
    func sidebarCloseToTheRight(_ window: NSWindow)
    func sidebarRename(_ window: NSWindow)
    func sidebarSetColor(_ color: TerminalTabColor, for window: NSWindow)
    func sidebarMoveToNewWindow(_ window: NSWindow)
    func sidebarMove(_ window: NSWindow, toIndex index: Int)
    func sidebarFocusTerminal()
    func sidebarSetPinned(_ pinned: Bool, for window: NSWindow)
    func sidebarSnooze(_ window: NSWindow, until: Date)
    func sidebarCustomSnooze(_ window: NSWindow)
    func sidebarWake(_ window: NSWindow)
    func sidebarResize(to width: CGFloat, finished: Bool)
}

/// Theme colors for the sidebar derived from the terminal's background.
final class TerminalTabSidebarAppearance: ObservableObject {
    @Published var background: Color = Color(nsColor: .windowBackgroundColor)
    @Published var foreground: Color = .primary
    @Published var accent: Color = .accentColor
    /// An opaque surface for a row lifted while reordering, so rows beneath it
    /// don't show through.
    @Published var lifted: Color = Color(nsColor: .controlBackgroundColor)

    /// Derive the sidebar colors from the window background.
    ///
    /// - Parameters:
    ///   - backgroundColor: The terminal background, including its opacity.
    ///   - opaque: Whether the window is drawn opaque (e.g. native fullscreen).
    ///   - glass: Whether a glass effect already draws the background.
    func update(backgroundColor: NSColor, opaque: Bool, glass: Bool) {
        let rgb = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let isLight = rgb.withAlphaComponent(1).isLightColor
        let foregroundColor: NSColor = isLight ? .black : .white

        let background: Color
        if glass {
            // The glass view behind the container already draws the background.
            background = .clear
        } else {
            // Use the terminal background as is so the sidebar continues the
            // titlebar above it. A hairline separates it from the terminal.
            let alpha = opaque ? 1 : rgb.alphaComponent
            background = Color(nsColor: rgb.withAlphaComponent(alpha))
        }

        if self.background != background { self.background = background }
        let base = rgb.withAlphaComponent(1)
        let lifted = Color(nsColor: base.blended(withFraction: 0.1, of: foregroundColor) ?? base)
        if self.lifted != lifted { self.lifted = lifted }
        let foreground = Color(nsColor: foregroundColor)
        if self.foreground != foreground { self.foreground = foreground }
    }
}

// MARK: Host View

/// AppKit container for the sidebar. It owns the hosting view and the resize handle
/// and is placed beside the terminal inside `TerminalViewContainer`.
final class TerminalTabSidebarHostView: NSView {
    let appearanceModel = TerminalTabSidebarAppearance()
    private let hostingView: NSHostingView<AnyView>
    private let resizeHandle = ResizeHandle()
    private weak var actions: TerminalTabSidebarActions?

    private(set) var model: TerminalTabSidebarModel

    /// Whether the sidebar is shown. Set synchronously by the controller from the
    /// model's published value so layout never reads a stale model value.
    var isShown: Bool = false

    /// The preferred width, mirrored from the model like `isShown`.
    var preferredWidth: CGFloat

    init(model: TerminalTabSidebarModel, actions: TerminalTabSidebarActions) {
        self.model = model
        self.actions = actions
        self.isShown = model.isVisible
        self.preferredWidth = model.width
        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onResize = { [weak self] delta, finished in
            guard let self else { return }
            self.actions?.sidebarResize(to: self.model.width + delta, finished: finished)
        }
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            resizeHandle.widthAnchor.constraint(equalToConstant: 7),
        ])

        rebuildRootView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Follow the terminal background. Controls such as the search field use the
    /// matching light or dark system appearance so they blend with the theme.
    func updateAppearance(backgroundColor: NSColor, opaque: Bool, glass: Bool) {
        appearanceModel.update(backgroundColor: backgroundColor, opaque: opaque, glass: glass)

        let rgb = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let name: NSAppearance.Name = rgb.withAlphaComponent(1).isLightColor ? .aqua : .darkAqua
        if appearance?.name != name {
            appearance = NSAppearance(named: name)
        }
    }

    /// Switch to another group's model, e.g. after the tab moved between windows.
    func setModel(_ model: TerminalTabSidebarModel) {
        guard self.model !== model else { return }
        self.model = model
        rebuildRootView()
    }

    private func rebuildRootView() {
        hostingView.rootView = AnyView(TerminalTabSidebarView(
            model: model,
            appearance: appearanceModel,
            actions: .init(actions)))
    }

    /// True if the window's first responder is inside the sidebar (e.g. the search field).
    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder.isDescendant(of: self) { return true }

        // Field editors are owned by the window, so check their delegate.
        if let textView = responder as? NSTextView,
           let delegate = textView.delegate as? NSView {
            return delegate.isDescendant(of: self)
        }
        return false
    }

    /// The handle sits slightly over the terminal so it's easy to grab; extend hit
    /// testing past our bounds for it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeHandle.frame.contains(local) { return resizeHandle }
        return super.hitTest(point)
    }

    /// A thin draggable area on the trailing edge of the sidebar.
    private final class ResizeHandle: NSView {
        var onResize: ((CGFloat, Bool) -> Void)?
        private var lastX: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            lastX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let lastX else { return }
            let x = event.locationInWindow.x
            self.lastX = x
            onResize?(x - lastX, false)
        }

        override func mouseUp(with event: NSEvent) {
            lastX = nil
            onResize?(0, true)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { "Resize Sidebar" }
    }
}

/// Holds the sidebar actions weakly so SwiftUI values don't retain the controller.
final class TerminalTabSidebarActionsBox {
    weak var value: TerminalTabSidebarActions?
    init(_ value: TerminalTabSidebarActions?) { self.value = value }
}

// MARK: Sidebar

struct TerminalTabSidebarView: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @ObservedObject var appearance: TerminalTabSidebarAppearance
    let actions: TerminalTabSidebarActionsBox

    @State private var searchFocused = false

    /// The in-progress reorder. Rows other than the dragged one animate aside
    /// when its target changes.
    @State private var reorder: Reorder?

    /// The dragged row's vertical offset. Kept apart from `reorder` so it follows
    /// the pointer without animation.
    @State private var dragOffset: CGFloat = 0

    private struct Reorder: Equatable {
        let id: ObjectIdentifier
        let startIndex: Int
        var targetIndex: Int

        /// Set once the row is released. The rows keep their offsets until the tab
        /// group reports the new order.
        var committed = false
    }

    static let rowSpacing: CGFloat = 4
    private static let listVerticalPadding: CGFloat = 6
    private static let rowStep = TerminalTabSidebarRow.height + rowSpacing
    private static let settleDuration: TimeInterval = 0.16
    private static let settleAnimation = Animation.easeOut(duration: settleDuration)

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if model.isSearching {
                        tabList(model.filteredTabs)
                            .overlay {
                                if model.filteredTabs.isEmpty {
                                    Text("No Matching Tabs")
                                        .font(.system(size: 12))
                                        .foregroundColor(appearance.foreground.opacity(0.4))
                                }
                            }
                    } else {
                        if !model.pinnedTabs.isEmpty {
                            sectionLabel("Pinned")
                            tabList(model.pinnedTabs)
                                .frame(height: shelfHeight(model.pinnedTabs.count, available: geometry.size.height))
                            Divider()
                        }
                        tabList(model.normalTabs)
                            .frame(maxHeight: .infinity)
                        if !model.snoozedTabs.isEmpty {
                            Divider()
                            Button {
                                model.snoozedExpanded.toggle()
                            } label: {
                                HStack {
                                    Image(systemName: model.snoozedExpanded ? "chevron.down" : "chevron.right")
                                    Text("Snoozed · \(model.snoozedTabs.count)")
                                    Spacer()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .padding(10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(model.snoozedExpanded ? "Collapse Snoozed" : "Expand Snoozed")
                            .accessibilityValue("\(model.snoozedTabs.count) tabs")
                            if model.snoozedExpanded {
                                tabList(model.snoozedTabs)
                                    .frame(height: shelfHeight(model.snoozedTabs.count, available: geometry.size.height))
                            }
                        }
                    }
                }
            }
        }
        .foregroundColor(appearance.foreground)
        .background(appearance.background.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(appearance.foreground.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func shelfHeight(_ count: Int, available: CGFloat) -> CGFloat {
        let contentHeight = CGFloat(count) * Self.rowStep - Self.rowSpacing + 2 * Self.listVerticalPadding
        return min(contentHeight, max(0, available * 0.3))
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private func tabList(_ tabs: [TerminalTabSidebarModel.Tab]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        row(tab)
                            .offset(y: tabs.contains(where: { $0.id == reorder?.id }) ? offset(for: tab.id, at: index) : 0)
                            .zIndex(reorder?.id == tab.id ? 1 : 0)
                            .gesture(reorderGesture(for: tab, at: index, in: tabs))
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, Self.listVerticalPadding)
            }
            .onAppear { scroll(proxy, to: model.selectedID, animated: false) }
            .onChange(of: model.selectedID) { id in scroll(proxy, to: id, animated: true) }
            .onChange(of: model.keyboardHighlightID) { id in scroll(proxy, to: id, animated: true) }
            .onChange(of: model.tabs.map(\.id)) { _ in tabOrderDidChange() }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            searchField

            TerminalTabSidebarIconButton(
                systemName: "plus",
                foreground: appearance.foreground,
                help: "New Tab"
            ) {
                actions.value?.sidebarNewTab()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(appearance.foreground.opacity(searchFocused ? 0.6 : 0.4))
                .accessibilityHidden(true)

            TerminalTabSidebarSearchField(
                text: $model.searchText,
                isFocused: $searchFocused,
                onMove: { model.moveKeyboardHighlight(by: $0) },
                onSubmit: activateKeyboardTarget,
                onCancel: {
                    model.searchText = ""
                    model.keyboardHighlightID = nil
                    actions.value?.sidebarFocusTerminal()
                })

            if model.isSearching {
                Button {
                    model.searchText = ""
                    model.keyboardHighlightID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(appearance.foreground.opacity(0.35))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(appearance.foreground.opacity(searchFocused ? 0.08 : 0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(appearance.foreground.opacity(searchFocused ? 0.16 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    private func row(_ tab: TerminalTabSidebarModel.Tab) -> some View {
        TerminalTabSidebarRow(
            item: tab.item,
            isSelected: tab.id == model.selectedID,
            isKeyboardHighlighted: searchFocused && tab.id == model.keyboardHighlightID,
            isLifted: reorder?.id == tab.id && reorder?.committed == false,
            isReordering: reorder != nil,
            canMoveToNewWindow: model.tabs.count > 1,
            canCloseOthers: model.normalTabs.contains { $0.id != tab.id },
            canCloseToTheRight: model.navigationTabs.drop(while: { $0.id != tab.id }).dropFirst()
                .contains { !$0.item.lifecycle.isSaved },
            foreground: appearance.foreground,
            accent: appearance.accent,
            lifted: appearance.lifted,
            perform: { perform($0, on: tab) })
    }

    // MARK: Reordering

    /// Rows are reordered with a plain drag gesture rather than system drag and
    /// drop. That keeps the row live under the pointer and avoids the drag image
    /// lingering after the drop.
    private func reorderGesture(
        for tab: TerminalTabSidebarModel.Tab,
        at index: Int,
        in visibleTabs: [TerminalTabSidebarModel.Tab]
    ) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard visibleTabs.count > 1, !model.isSearching else { return }
                let current = reorder ?? Reorder(id: tab.id, startIndex: index, targetIndex: index)
                guard current.id == tab.id, !current.committed else { return }

                dragOffset = value.translation.height
                let target = Self.targetIndex(
                    from: current.startIndex,
                    offset: value.translation.height,
                    count: visibleTabs.count)
                if reorder == nil {
                    reorder = current
                }
                if target != current.targetIndex {
                    withAnimation(Self.settleAnimation) {
                        reorder?.targetIndex = target
                    }
                }
            }
            .onEnded { _ in
                guard let current = reorder, current.id == tab.id, !current.committed else { return }
                finishReorder(current, in: visibleTabs)
            }
    }

    private func finishReorder(_ current: Reorder, in visibleTabs: [TerminalTabSidebarModel.Tab]) {
        let start = current.startIndex
        let target = current.targetIndex
        guard start != target,
              visibleTabs.indices.contains(start),
              visibleTabs.indices.contains(target),
              let window = visibleTabs[start].window,
              let index = TerminalTabSidebarModel.fullOrderIndex(
                forDropOnto: visibleTabs[target].id,
                in: model.tabs.map(\.id))
        else {
            withAnimation(Self.settleAnimation) { cancelReorder() }
            return
        }

        // Ease the dragged row into its slot using offsets only. The list order
        // stays the same until the move happens, so nothing reflows mid-animation.
        withAnimation(Self.settleAnimation) {
            reorder?.committed = true
            dragOffset = CGFloat(target - start) * Self.rowStep
        }

        let id = current.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
            guard reorder?.id == id, reorder?.committed == true else { return }
            actions.value?.sidebarMove(window, toIndex: index)

            // If the move didn't happen, put the rows back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard reorder?.id == id, reorder?.committed == true else { return }
                withAnimation(Self.settleAnimation) { cancelReorder() }
            }
        }
    }

    /// The tab group reported a new order. Once a released row is waiting for it,
    /// the new order puts every row exactly where its offset already shows it, so
    /// clearing the offsets without animation is invisible.
    private func tabOrderDidChange() {
        guard reorder?.committed == true else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { cancelReorder() }
    }

    private func cancelReorder() {
        reorder = nil
        dragOffset = 0
    }

    private func offset(for id: ObjectIdentifier, at index: Int) -> CGFloat {
        guard let reorder else { return 0 }
        if reorder.id == id { return dragOffset }
        return Self.displacement(
            ofRowAt: index,
            start: reorder.startIndex,
            target: reorder.targetIndex) * Self.rowStep
    }

    /// The target slot for a row dragged `offset` points from `start`.
    static func targetIndex(from start: Int, offset: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let moved = Int((offset / rowStep).rounded())
        return min(max(start + moved, 0), count - 1)
    }

    /// How many slots a row moves to make room while another row is dragged from
    /// `start` to `target`: -1 (up), 0, or 1 (down).
    static func displacement(ofRowAt index: Int, start: Int, target: Int) -> CGFloat {
        if start < target, index > start, index <= target { return -1 }
        if target < start, index >= target, index < start { return 1 }
        return 0
    }

    private func perform(_ action: TerminalTabSidebarRow.Action, on tab: TerminalTabSidebarModel.Tab) {
        guard let window = tab.window, let actions = actions.value else { return }
        switch action {
        case .select: actions.sidebarSelect(window)
        case .close: actions.sidebarClose(window)
        case .closeOthers: actions.sidebarCloseOthers(window)
        case .closeToTheRight: actions.sidebarCloseToTheRight(window)
        case .rename: actions.sidebarRename(window)
        case .color(let color): actions.sidebarSetColor(color, for: window)
        case .moveToNewWindow: actions.sidebarMoveToNewWindow(window)
        case .pin: actions.sidebarSetPinned(!tab.item.lifecycle.isPinned, for: window)
        case .snooze(let until): actions.sidebarSnooze(window, until: until)
        case .customSnooze: actions.sidebarCustomSnooze(window)
        case .wake: actions.sidebarWake(window)
        }
    }

    private func activateKeyboardTarget() {
        guard let tab = model.keyboardActivationTarget, let window = tab.window else { return }
        model.searchText = ""
        model.keyboardHighlightID = nil
        actions.value?.sidebarSelect(window)
        actions.value?.sidebarFocusTerminal()
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: ObjectIdentifier?, animated: Bool) {
        guard let id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }
}

// MARK: Row

struct TerminalTabSidebarRow: View {
    enum Action {
        case select
        case close
        case closeOthers
        case closeToTheRight
        case rename
        case color(TerminalTabColor)
        case moveToNewWindow
        case pin
        case snooze(Date)
        case customSnooze
        case wake
    }

    static let height: CGFloat = 44
    static let iconSize: CGFloat = 16
    private static let hoverButtonSize: CGFloat = 18

    @ObservedObject var item: TerminalTabSidebarItem
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    let isLifted: Bool
    let isReordering: Bool
    let canMoveToNewWindow: Bool
    let canCloseOthers: Bool
    let canCloseToTheRight: Bool
    let foreground: Color
    let accent: Color
    let lifted: Color
    let perform: (Action) -> Void

    @State private var hoveringRaw = false
    @AppStorage("TerminalSnoozeMorningHour", store: .ghostty) private var morningHour = 9

    /// Hover feedback is suppressed while any row is being dragged.
    private var hovering: Bool { hoveringRaw && !isReordering }

    private var title: String {
        item.title.isEmpty ? "Terminal" : item.title
    }

    var body: some View {
        HStack(spacing: 9) {
            TerminalAppIconView(icon: item.icon, foreground: foreground, size: Self.iconSize)
                .opacity(isSelected || item.icon != .terminal ? 1 : 0.8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundColor(foreground.opacity(isSelected ? 0.95 : 0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let until = item.lifecycle.snoozedUntil {
                    Text("Until \(until.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundColor(foreground.opacity(0.5))
                        .lineLimit(1)
                } else if item.lifecycle.wokeAt != nil {
                    Label("Woke", systemImage: "alarm")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                } else if let directory = item.remoteLabel ?? item.displayDirectory {
                    Text(directory)
                        .font(.system(size: 11))
                        .foregroundColor(foreground.opacity(isSelected ? 0.5 : 0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let issue = item.restorationIssue {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .help(issue)
                    .accessibilityLabel(issue)
            }
            trailing
                .frame(minWidth: 24, alignment: .trailing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(background)
        .overlay(alignment: .leading) { colorStripe }
        .contentShape(Rectangle())
        .onTapGesture { perform(.select) }
        .onHover { hoveringRaw = $0 }
        .help(tooltip)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { perform(.select) }
        .accessibilityAction(named: "Close Tab") { perform(.close) }
        .accessibilityAction(named: "Rename Tab") { perform(.rename) }
        .accessibilityAction(named: item.lifecycle.isPinned ? "Unpin Tab" : "Pin Tab") { perform(.pin) }
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            HStack(spacing: 1) {
                TerminalTabSidebarIconButton(
                    systemName: item.lifecycle.isPinned ? "pin.slash" : "pin",
                    foreground: foreground,
                    help: item.lifecycle.isPinned ? "Unpin Tab" : "Pin Tab",
                    size: Self.hoverButtonSize,
                    symbolSize: 10
                ) {
                    perform(.pin)
                }

                if item.lifecycle.isSnoozed {
                    TerminalTabSidebarIconButton(
                        systemName: "alarm",
                        foreground: foreground,
                        help: "Wake Tab",
                        size: Self.hoverButtonSize,
                        symbolSize: 10
                    ) {
                        perform(.wake)
                    }
                } else {
                    TerminalTabSidebarIconMenu(
                        systemName: "moon.zzz",
                        foreground: foreground,
                        help: "Snooze Tab",
                        size: Self.hoverButtonSize,
                        symbolSize: 10
                    ) {
                        snoozeMenuItems
                    }
                }

                TerminalTabSidebarIconButton(
                    systemName: "xmark",
                    foreground: foreground,
                    help: "Close Tab",
                    size: Self.hoverButtonSize,
                    symbolSize: 8.5,
                    symbolWeight: .bold
                ) {
                    perform(.close)
                }
            }
            .fixedSize()
        } else if let shortcut = item.shortcut, !shortcut.isEmpty {
            Text(shortcut)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundColor(foreground.opacity(isSelected ? 0.4 : 0.28))
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var background: some View {
        if isLifted {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(lifted)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(restingFill)
                .overlay {
                    if isKeyboardHighlighted {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }

    private var restingFill: Color {
        if isSelected { return foreground.opacity(0.09) }
        if hovering { return foreground.opacity(0.045) }
        return .clear
    }

    @ViewBuilder
    private var colorStripe: some View {
        if let color = item.tabColor.displayColor {
            Capsule()
                .fill(Color(nsColor: color))
                .frame(width: 3, height: 18)
                .padding(.leading, 2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(item.lifecycle.isPinned ? "Unpin Tab" : "Pin Tab") { perform(.pin) }
        Menu("Snooze") { snoozeMenuItems }
        if item.lifecycle.isSnoozed {
            Button("Wake Tab") { perform(.wake) }
        }
        Divider()
        Button("Rename Tab…") { perform(.rename) }
        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    perform(.color(color))
                } label: {
                    if color == item.tabColor {
                        Label(color.localizedName, systemImage: "checkmark")
                    } else {
                        Text(color.localizedName)
                    }
                }
            }
        }
        Divider()
        Button("Move Tab to New Window") { perform(.moveToNewWindow) }
            .disabled(!canMoveToNewWindow)
        Divider()
        Button("Close Tab") { perform(.close) }
        Button("Close Other Tabs") { perform(.closeOthers) }
            .disabled(!canCloseOthers)
        Button("Close Tabs to the Right") { perform(.closeToTheRight) }
            .disabled(!canCloseToTheRight)
    }

    /// The snooze presets, shared by the context menu and the hover button.
    @ViewBuilder
    private var snoozeMenuItems: some View {
        ForEach(TerminalSnoozePreset.allCases, id: \.self) { preset in
            Button(preset.rawValue) {
                let hour = (0..<24).contains(morningHour) ? morningHour : 9
                if let deadline = preset.deadline(morningHour: hour) { perform(.snooze(deadline)) }
            }
        }
        Button("Custom…") { perform(.customSnooze) }
        Divider()
        Picker("Morning Time", selection: $morningHour) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        }
    }

    private var tooltip: String {
        [title, item.remoteLabel ?? item.displayDirectory, item.restorationIssue].compactMap { $0 }.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if !item.lifecycle.isSnoozed, item.lifecycle.wokeAt == nil,
           let directory = item.remoteLabel ?? item.displayDirectory { parts.append(directory) }
        if item.icon != .terminal { parts.append(item.icon.accessibilityName) }
        if item.lifecycle.isPinned { parts.append("Pinned") }
        if let until = item.lifecycle.snoozedUntil {
            parts.append("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
        } else if item.lifecycle.wokeAt != nil {
            parts.append("Woke")
        }
        if let issue = item.restorationIssue { parts.append(issue) }
        return parts.joined(separator: ", ")
    }
}

// MARK: Icon Button

/// A small borderless symbol button with a hover highlight, used for the new tab
/// button and the row's hover buttons.
struct TerminalTabSidebarIconButton: View {
    let systemName: String
    let foreground: Color
    let help: String
    var size: CGFloat = 26
    var symbolSize: CGFloat = 12
    var symbolWeight: Font.Weight = .medium
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TerminalTabSidebarIconLabel(
                systemName: systemName,
                foreground: foreground,
                hovering: hovering,
                size: size,
                symbolSize: symbolSize,
                symbolWeight: symbolWeight)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Like `TerminalTabSidebarIconButton`, but clicking it opens a menu.
struct TerminalTabSidebarIconMenu<Content: View>: View {
    let systemName: String
    let foreground: Color
    let help: String
    var size: CGFloat = 26
    var symbolSize: CGFloat = 12
    var symbolWeight: Font.Weight = .medium
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            TerminalTabSidebarIconLabel(
                systemName: systemName,
                foreground: foreground,
                hovering: hovering,
                size: size,
                symbolSize: symbolSize,
                symbolWeight: symbolWeight)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TerminalTabSidebarIconLabel: View {
    let systemName: String
    let foreground: Color
    let hovering: Bool
    let size: CGFloat
    let symbolSize: CGFloat
    let symbolWeight: Font.Weight

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: symbolWeight))
            .foregroundColor(foreground.opacity(hovering ? 0.85 : 0.55))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(foreground.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
    }
}

// MARK: Search Field

/// A borderless text field that forwards arrow, return, and escape keys for keyboard
/// navigation of the tab list.
struct TerminalTabSidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.placeholderString = "Search Tabs"
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.setAccessibilityRole(.textField)
        field.setAccessibilityLabel("Search Tabs")
        field.onFocusChange = { focused in
            DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // The search text is shared by every tab of the group, so this field may be
        // updated from another tab's field.
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalTabSidebarSearchField

        init(_ parent: TerminalTabSidebarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.complete(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    final class FocusReportingTextField: NSTextField {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { onFocusChange?(true) }
            return result
        }
    }
}
