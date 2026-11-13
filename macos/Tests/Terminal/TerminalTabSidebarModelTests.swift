import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

// MARK: Helpers

/// UserDefaults isolated to a single test.
private final class TemporaryDefaults {
    let suiteName = "ghostty-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makeWindow(_ title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: true)
    window.isReleasedWhenClosed = false
    window.title = title
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "ghostty-sidebar-tests-\(title)"
    return window
}

/// Builds a model whose items are created for plain test windows.
@MainActor
private func makeModel(
    defaults: UserDefaults,
    items: [ObjectIdentifier: TerminalTabSidebarItem]
) -> TerminalTabSidebarModel {
    let model = TerminalTabSidebarModel(preferences: .init(defaults: defaults))
    model.itemProvider = { items[ObjectIdentifier($0)] }
    return model
}

private func item(_ title: String, _ directory: String? = nil) -> TerminalTabSidebarItem {
    let item = TerminalTabSidebarItem()
    item.title = title
    item.directory = directory
    return item
}

// MARK: Filtering

struct TerminalTabSidebarFilterTests {
    struct MatchCase: Sendable, CustomTestStringConvertible {
        let query: String
        let title: String
        let directory: String?
        let expected: Bool

        init(_ query: String, _ title: String, _ directory: String?, _ expected: Bool) {
            self.query = query
            self.title = title
            self.directory = directory
            self.expected = expected
        }

        var testDescription: String { "\"\(query)\" in \"\(title)\"" }
    }

    @Test(arguments: [
        MatchCase("", "anything", nil, true),
        MatchCase("   ", "anything", nil, true),
        MatchCase("vim", "vim README.md", nil, true),
        MatchCase("VIM", "vim README.md", nil, true),
        MatchCase("cafe", "Café", nil, true),
        MatchCase("ghostty", "zsh", "~/dev/ghostty", true),
        MatchCase("dev zsh", "zsh", "~/dev/ghostty", true),
        MatchCase("dev fish", "zsh", "~/dev/ghostty", false),
        MatchCase("missing", "zsh", nil, false),
    ])
    func matches(_ test: MatchCase) {
        #expect(TerminalTabSidebarModel.matches(query: test.query, title: test.title, directory: test.directory) == test.expected)
    }

    @MainActor @Test func searchFiltersTabsInFullOrder() throws {
        let defaults = TemporaryDefaults()
        let windows = ["a", "b", "c", "d"].map(makeWindow)
        defer { windows.forEach { $0.close() } }
        let items = [item("zsh", "/tmp"), item("vim", "/src"), item("zsh", "/src/app"), item("htop")]
        let model = makeModel(
            defaults: defaults.defaults,
            items: Dictionary(uniqueKeysWithValues: zip(windows.map(ObjectIdentifier.init), items)))

        windows[0].orderFront(nil)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            previous.addTabbedWindow(next, ordered: .above)
        }
        model.bind(to: try #require(windows[0].tabGroup))
        #expect(model.tabs.count == 4)

        model.searchText = "src"
        #expect(model.filteredTabs.map(\.id) == [windows[1], windows[2]].map(ObjectIdentifier.init))
        #expect(model.isSearching)

        // Searching never changes the full tab order used for numbering.
        #expect(model.tabs.map(\.id) == windows.map(ObjectIdentifier.init))

        model.searchText = "nothing-matches"
        #expect(model.filteredTabs.isEmpty)

        model.searchText = ""
        #expect(model.filteredTabs.count == 4)
        #expect(!model.isSearching)
    }
}

// MARK: Reordering

struct TerminalTabSidebarReorderTests {
    @MainActor @Test(arguments: [
        (false, true, 0), (false, true, 1), (false, true, 3),
        (true, false, 0), (true, false, 1), (true, false, 3),
        (false, false, 0), (false, false, 1), (false, false, 2),
        (true, true, 0), (true, true, 1), (true, true, 2),
    ])
    func dropUsesExactSectionSlotWithoutChangingSelection(sourcePinned: Bool, targetPinned: Bool, index: Int) throws {
        let defaults = TemporaryDefaults()
        let windows = ["pin-a", "tab-a", "pin-b", "sleep", "tab-b", "pin-c", "tab-c"].map(makeWindow)
        defer { windows.forEach { $0.close() } }
        let items = windows.map { item($0.title) }
        for pin in [0, 2, 5] { items[pin].lifecycle.pin(true) }
        _ = items[3].lifecycle.snooze(until: .distantFuture)
        let model = makeModel(defaults: defaults.defaults,
            items: Dictionary(uniqueKeysWithValues: zip(windows.map(ObjectIdentifier.init), items)))
        windows[0].orderFront(nil)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            previous.addTabbedWindow(next, ordered: .above)
        }
        let group = try #require(windows[0].tabGroup)
        model.bind(to: group)
        group.selectedWindow = windows[6]
        let selected = group.selectedWindow
        let source = sourcePinned ? model.pinnedTabs[1] : model.normalTabs[1]
        var expectedPins = model.pinnedTabs.map(\.id).filter { $0 != source.id }
        var expectedRegular = model.normalTabs.map(\.id).filter { $0 != source.id }
        if targetPinned { expectedPins.insert(source.id, at: index) } else { expectedRegular.insert(source.id, at: index) }

        model.move(source, to: targetPinned ? .pinned : .regular, at: index)

        #expect(model.pinnedTabs.map(\.id) == expectedPins)
        #expect(model.normalTabs.map(\.id) == expectedRegular)
        #expect(source.item.lifecycle.isPinned == targetPinned)
        #expect(model.snoozedTabs.map(\.id) == [ObjectIdentifier(windows[3])])
        #expect(group.selectedWindow === selected)
    }

    @MainActor @Test func singleTabCanEnterAndLeaveAnEmptyPinnedSection() throws {
        let defaults = TemporaryDefaults()
        let window = makeWindow("only")
        defer { window.close() }
        let tabItem = item("only")
        let model = makeModel(defaults: defaults.defaults, items: [ObjectIdentifier(window): tabItem])
        model.provisionalWindow = window
        let tab = try #require(model.tabs.first)

        model.move(tab, to: .pinned, at: 0)
        #expect(model.pinnedTabs.map(\.id) == [tab.id])
        #expect(model.normalTabs.isEmpty)
        model.move(tab, to: .regular, at: 0)
        #expect(model.pinnedTabs.isEmpty)
        #expect(model.normalTabs.map(\.id) == [tab.id])

        model.move(tab, to: .pinned, at: 1)
        #expect(!tabItem.lifecycle.isPinned)
        model.snooze(tab, until: .distantFuture)
        model.move(tab, to: .pinned, at: 0)
        #expect(tabItem.lifecycle.isSnoozed)
        #expect(!tabItem.lifecycle.isPinned)
    }

    @MainActor @Test func snoozedReorderingDoesNotWakeOrPinTabs() throws {
        let defaults = TemporaryDefaults()
        let windows = ["sleep-a", "sleep-b"].map(makeWindow)
        defer { windows.forEach { $0.close() } }
        let items = windows.map { item($0.title) }
        for item in items { _ = item.lifecycle.snooze(until: .distantFuture) }
        let model = makeModel(defaults: defaults.defaults,
            items: Dictionary(uniqueKeysWithValues: zip(windows.map(ObjectIdentifier.init), items)))
        windows[0].orderFront(nil)
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        model.bind(to: try #require(windows[0].tabGroup))

        model.move(model.snoozedTabs[1], to: .snoozed, at: 0)

        #expect(model.snoozedTabs.map(\.id) == windows.reversed().map(ObjectIdentifier.init))
        #expect(items.allSatisfy { $0.lifecycle.isSnoozed && !$0.lifecycle.isPinned })
        #expect(model.navigationTabs.isEmpty)
    }

    @MainActor @Test(arguments: [
        (0, TerminalTabSidebarDrag.Section.regular, TerminalTabSidebarDrag.Section.regular, 1),
        (0, .regular, .pinned, 1),
        (1, .regular, .pinned, 2),
        (3, .regular, .pinned, 4),
        (1, .pinned, .regular, 1),
        (3, .pinned, .regular, 3),
        (3, .pinned, .pinned, 3),
    ])
    func pinnedShelfFitsThePreviewWithoutCollapsingTheSource(
        pins: Int, source: TerminalTabSidebarDrag.Section, target: TerminalTabSidebarDrag.Section, expected: Int
    ) {
        let window = makeWindow("preview")
        defer { window.close() }
        let session = TerminalTabSidebarDrag.Session(
            tab: .init(window: window, item: item("preview")), source: .init(section: source, index: 0),
            counts: [.pinned: pins, .regular: 1], grabOffset: .zero, activationY: 0,
            target: .init(section: target, index: 0))
        #expect(session.pinnedShelfCount == expected)
    }

    @Test func insertionSlotsClampToTheSectionAndIncludeItsEnd() {
        #expect(TerminalTabSidebarDrag.insertionIndex(center: -100, contentTop: 20, count: 3) == 0)
        #expect(TerminalTabSidebarDrag.insertionIndex(center: 100, contentTop: 20, count: 3) == 1)
        #expect(TerminalTabSidebarDrag.insertionIndex(center: 500, contentTop: 20, count: 3) == 3)
        #expect(TerminalTabSidebarDrag.insertionIndex(center: 100, contentTop: 20, count: 0) == 0)
    }

    @Test func sectionBoundaryResistsJitterAndOnlyCrossesInTheDragDirection() {
        let section = TerminalTabSidebarDrag.section
        #expect(section(99, 101, .regular, 94, 106) == .regular)
        #expect(section(93, 99, .regular, 94, 106) == .pinned)
        #expect(section(101, 93, .pinned, 94, 106) == .pinned)
        #expect(section(107, 101, .pinned, 94, 106) == .regular)
        #expect(section(80, 80, .regular, 94, 106) == .regular)
        #expect(section(80, 70, .regular, 94, 106) == .regular)
    }

    @MainActor @Test func keyboardHighlightMovesWithinFilteredTabs() throws {
        let defaults = TemporaryDefaults()
        let first = makeWindow("first")
        let model = makeModel(defaults: defaults.defaults, items: [ObjectIdentifier(first): item("zsh")])
        model.provisionalWindow = first

        model.moveKeyboardHighlight(by: 1)
        #expect(model.keyboardHighlightID == ObjectIdentifier(first))
        model.moveKeyboardHighlight(by: 5)
        #expect(model.keyboardHighlightID == ObjectIdentifier(first))
        #expect(model.keyboardActivationTarget?.id == ObjectIdentifier(first))

        model.searchText = "no-match"
        model.moveKeyboardHighlight(by: 1)
        #expect(model.keyboardHighlightID == nil)
        #expect(model.keyboardActivationTarget == nil)
    }

    @MainActor @Test func searchRefreshesWhenTabMetadataChanges() throws {
        let defaults = TemporaryDefaults()
        let window = makeWindow("metadata")
        let tabItem = item("zsh", "/tmp")
        let model = makeModel(defaults: defaults.defaults, items: [ObjectIdentifier(window): tabItem])
        model.provisionalWindow = window

        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        // Not searching: item changes don't touch the model.
        tabItem.title = "vim"
        #expect(changes == 0)

        model.searchText = "claude"
        #expect(model.filteredTabs.isEmpty)
        changes = 0

        // A tab that starts matching appears.
        tabItem.title = "claude"
        #expect(changes == 1)
        #expect(model.filteredTabs.map(\.id) == [ObjectIdentifier(window)])

        // A tab that stops matching disappears, including by directory.
        model.searchText = "projects"
        tabItem.directory = "/Users/me/projects"
        #expect(model.filteredTabs.count == 1)
        changes = 0
        tabItem.directory = "/tmp"
        #expect(changes == 1)
        #expect(model.filteredTabs.isEmpty)
    }
}

// MARK: Group Synchronization

@MainActor
struct TerminalTabSidebarGroupTests {
    @Test func modelFollowsTabGroupMembershipAndOrder() async throws {
        let defaults = TemporaryDefaults()
        let a = makeWindow("a"), b = makeWindow("b"), c = makeWindow("c")
        defer { [a, b, c].forEach { $0.close() } }
        let items = Dictionary(uniqueKeysWithValues: [a, b, c].map { (ObjectIdentifier($0), item($0.title)) })
        let model = makeModel(defaults: defaults.defaults, items: items)

        a.orderFront(nil)
        a.addTabbedWindow(b, ordered: .above)
        b.addTabbedWindow(c, ordered: .above)
        let group = try #require(a.tabGroup)

        model.bind(to: group)
        #expect(model.tabs.map(\.id) == [a, b, c].map(ObjectIdentifier.init))
        #expect(TerminalTabSidebarModel.registered(for: group) === model)

        // Reorder through AppKit; the model re-reads order from the tab group.
        group.removeWindow(c)
        a.addTabbedWindow(c, ordered: .below)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.tabs.map(\.id) == [c, a, b].map(ObjectIdentifier.init))

        // Membership changes are observed.
        group.removeWindow(b)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.tabs.map(\.id) == [c, a].map(ObjectIdentifier.init))
    }

    @Test func sharedStateIsPerGroupAndContinuesIntoNewGroups() throws {
        let defaults = TemporaryDefaults()
        let a = makeWindow("a"), b = makeWindow("b")
        defer { [a, b].forEach { $0.close() } }
        let model = makeModel(defaults: defaults.defaults, items: [:])

        a.orderFront(nil)
        a.addTabbedWindow(b, ordered: .above)
        let group = try #require(a.tabGroup)
        model.bind(to: group)

        model.setVisible(true, persist: false)
        model.setWidth(333, persist: false)
        model.searchText = "zsh"

        // Every tab in the group resolves to the same model.
        #expect(TerminalTabSidebarModel.registered(for: try #require(b.tabGroup)) === model)

        // A tab moved to a new window continues visibility and width, but not search.
        let continued = TerminalTabSidebarModel(continuing: model)
        #expect(continued.isVisible)
        #expect(continued.width == 333)
        #expect(continued.searchText.isEmpty)
        #expect(continued.tabGroup == nil)
    }
}

// MARK: Preferences

struct TerminalTabSidebarPreferencesTests {
    @Test func defaultsWhenUnset() {
        let defaults = TemporaryDefaults()
        let preferences = TerminalTabSidebarPreferences(defaults: defaults.defaults)
        #expect(!preferences.isVisible)
        #expect(preferences.width == TerminalTabSidebarPreferences.defaultWidth)
    }

    @Test func persistsLastUsedState() {
        let defaults = TemporaryDefaults()
        let preferences = TerminalTabSidebarPreferences(defaults: defaults.defaults)
        let model = TerminalTabSidebarModel(preferences: preferences)

        model.setVisible(true, persist: true)
        model.setWidth(300, persist: false)
        #expect(preferences.width == TerminalTabSidebarPreferences.defaultWidth)
        model.setWidth(310, persist: true)

        // New windows start from the persisted state.
        let next = TerminalTabSidebarModel(preferences: preferences)
        #expect(next.isVisible)
        #expect(next.width == 310)

        // Existing windows keep their own state when defaults change later.
        preferences.isVisible = false
        #expect(next.isVisible)
    }

    @Test func clampsWidth() {
        let defaults = TemporaryDefaults()
        let preferences = TerminalTabSidebarPreferences(defaults: defaults.defaults)
        preferences.width = 10
        #expect(preferences.width == TerminalTabSidebarPreferences.minimumWidth)
        preferences.width = 10_000
        #expect(preferences.width == TerminalTabSidebarPreferences.maximumWidth)
        #expect(TerminalTabSidebarPreferences.clamp(width: .nan) == TerminalTabSidebarPreferences.defaultWidth)
    }

    @Test(arguments: [
        (Ghostty.MacOSTabLayout?.none, false, false),
        (Ghostty.MacOSTabLayout?.none, true, true),
        (Ghostty.MacOSTabLayout.vertical, false, true),
        (Ghostty.MacOSTabLayout.horizontal, true, false),
    ])
    func configuredLayoutOverridesLastUsed(layout: Ghostty.MacOSTabLayout?, lastUsed: Bool, expected: Bool) {
        #expect(TerminalTabSidebarModel.initialVisibility(configuredLayout: layout, lastUsed: lastUsed) == expected)
    }

    @Test func parsesTabLayoutConfig() throws {
        #expect(try TemporaryConfig("").macosTabLayout == nil)
        #expect(try TemporaryConfig("macos-tab-layout = vertical").macosTabLayout == .vertical)
        #expect(try TemporaryConfig("macos-tab-layout = horizontal").macosTabLayout == .horizontal)
    }

    @Test func sidebarWidthPreservesTerminalSpace() {
        let minTerminal = TerminalViewContainer.minimumTerminalWidthBesideSidebar
        // Wide window: preferred width is used.
        #expect(TerminalViewContainer.effectiveSidebarWidth(preferred: 280, containerWidth: 1200) == 280)
        // Narrow window: terminal keeps its minimum width.
        #expect(TerminalViewContainer.effectiveSidebarWidth(preferred: 400, containerWidth: 700) == 700 - minTerminal)
        // Rows are never compacted below the minimum unless the window is tiny.
        #expect(TerminalViewContainer.effectiveSidebarWidth(preferred: 280, containerWidth: 450)
                == TerminalTabSidebarPreferences.minimumWidth)
        #expect(TerminalViewContainer.effectiveSidebarWidth(preferred: 280, containerWidth: 300) == 150)
    }
}

// MARK: Items and Titles

struct TerminalTabSidebarItemTests {
    @Test(arguments: [
        ("/Users/me", "~"),
        ("/Users/me/", "~"),
        ("/Users/me/dev/ghostty", "~/dev/ghostty"),
        ("/Users/meow", "/Users/meow"),
        ("/tmp", "/tmp"),
    ])
    func abbreviatesHome(path: String, expected: String) {
        #expect(TerminalTabSidebarItem.abbreviate(path: path, home: "/Users/me") == expected)
    }

    @MainActor @Test func manualTitleIsPreserved() throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        try #require(appDelegate.ghostty.app != nil)

        // An empty tree avoids spawning a shell.
        let controller = BaseTerminalController(appDelegate.ghostty, surfaceTree: .init())
        let window = makeWindow("controller")
        defer { window.close() }
        controller.window = window

        controller.titleOverride = "Deploys"
        #expect(controller.sidebarItem.title == "Deploys")
        #expect(window.title == "Deploys")

        controller.titleOverride = nil
        #expect(controller.sidebarItem.title == window.title)
        #expect(controller.sidebarItem.title != "Deploys")
    }
}

// MARK: Icons

@MainActor
struct TerminalTabSidebarIconTests {
    // Keep sampling independent of WindowServer occlusion notifications.
    private final class OnScreenWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { .visible }
    }

    @Test func focusChangeRefreshesIconWithoutWaitingForTimer() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(appDelegate.ghostty, withBaseConfig: config)
        let surface = try #require(controller.surfaceTree.first)
        let window = OnScreenWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        controller.window = window
        let model = controller.sidebarModel
        let tabItem = controller.sidebarItem
        tabItem.foregroundPID = { ProcessInfo.processInfo.processIdentifier }
        tabItem.icon = .codex

        // A provisional model has no sampling timer.
        model.provisionalWindow = window
        model.setVisible(true, persist: false)
        try #require(model.tabs.first?.item === tabItem)
        try #require(model.tabGroup == nil)

        controller.focusedSurfaceDidChange(to: surface)
        await finishPendingIconResolutions()

        #expect(tabItem.icon == .terminal)
    }

    @Test func ignoresIconResolvedForPreviousForegroundProcess() async throws {
        let defaults = TemporaryDefaults()
        let window = OnScreenWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tabItem = item("terminal")
        var pid: pid_t? = ProcessInfo.processInfo.processIdentifier
        tabItem.foregroundPID = { pid }
        tabItem.icon = .pi
        let model = makeModel(defaults: defaults.defaults, items: [ObjectIdentifier(window): tabItem])
        model.provisionalWindow = window
        model.setVisible(true, persist: false)

        model.sampleIcons()
        pid = nil
        await finishPendingIconResolutions()

        #expect(tabItem.icon == .pi)

        model.sampleIcons()
        #expect(tabItem.icon == .terminal)
    }

    private func finishPendingIconResolutions() async {
        await withCheckedContinuation { continuation in
            TerminalAppIconResolver.shared.resolve(pids: [ProcessInfo.processInfo.processIdentifier]) { _ in
                continuation.resume()
            }
        }
    }
}

struct TerminalTabSidebarLifecycleTests {
    @MainActor @Test(arguments: [0, 1, 2]) func wakingPlacesTabFirstWithoutChangingSelection(index: Int) throws {
        let defaults = TemporaryDefaults()
        let windows = ["a", "b", "c"].map(makeWindow)
        defer { windows.forEach { $0.close() } }
        let items = windows.map { item($0.title) }
        let model = makeModel(defaults: defaults.defaults,
            items: Dictionary(uniqueKeysWithValues: zip(windows.map(ObjectIdentifier.init), items)))
        windows[0].orderFront(nil)
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        let group = try #require(windows[0].tabGroup)
        model.bind(to: group)
        let selected = group.selectedWindow
        let tab = model.tabs[index]
        model.snooze(tab, until: .distantFuture)
        model.wake(tab)
        model.refresh()
        #expect(model.normalTabs.first?.window === windows[index])
        #expect(group.selectedWindow === selected)
    }

    @MainActor @Test func sectionsNavigationAndSearchKeepSnoozedTabsOutOfTheWay() throws {
        let defaults = TemporaryDefaults()
        let windows = ["normal", "pinned", "snoozed"].map(makeWindow)
        defer { windows.forEach { $0.close() } }
        let items = [item("normal"), item("pinned"), item("snoozed")]
        let model = makeModel(defaults: defaults.defaults,
            items: Dictionary(uniqueKeysWithValues: zip(windows.map(ObjectIdentifier.init), items)))
        windows[0].orderFront(nil)
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        model.bind(to: try #require(windows[0].tabGroup))
        model.setPinned(true, for: model.tabs[1])
        model.snooze(model.tabs[2], until: .distantFuture)
        #expect(model.navigationTabs.map(\.id) == [windows[1], windows[0]].map(ObjectIdentifier.init))
        #expect(model.snoozedTabs.map(\.id) == [ObjectIdentifier(windows[2])])
        #expect(model.filteredTabs.count == 2)
        model.searchText = "snoozed"
        #expect(model.filteredTabs.map(\.id) == [ObjectIdentifier(windows[2])])
        #expect(items[2].lifecycle.isSnoozed)
        model.searchText = ""
        let selected = windows[0].tabGroup?.selectedWindow
        model.wakeDueTabs(now: .distantFuture)
        model.refresh()
        #expect(model.snoozedTabs.isEmpty)
        #expect(model.normalTabs.first?.id == ObjectIdentifier(windows[2]))
        #expect(items[2].lifecycle.wokeAt == .distantFuture)
        #expect(windows[0].tabGroup?.selectedWindow === selected)
    }
}

// MARK: Shortcut Dispatch

struct TerminalTabSidebarShortcutTests {
    @MainActor @Test func defaultConfigLeavesCmdBForSidebar() throws {
        let config = try TemporaryConfig("")
        #expect(!AppDelegate.configClaimsTabSidebarShortcut(config))

        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        let item = NSMenuItem()
        manager.syncMenuShortcut(config, action: "new_tab", menuItem: item)
        #expect(!manager.hasShortcut(AppDelegate.tabSidebarShortcut))
    }

    @Test(arguments: [
        "keybind = super+b=new_tab",
        "keybind = super+b=text:\\x02",
        "keybind = super+b=toggle_split_zoom",
    ])
    func explicitBindingClaimsCmdB(_ configText: String) throws {
        let config = try TemporaryConfig(configText)
        #expect(AppDelegate.configClaimsTabSidebarShortcut(config))
    }

    @MainActor @Test func menuBindingClaimsCmdB() throws {
        // Use an action without a default binding so Cmd+B is its menu shortcut.
        let config = try TemporaryConfig("keybind = super+b=toggle_window_float_on_top")
        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        // The manager holds menu items weakly, so keep the item alive.
        let item = NSMenuItem()
        manager.syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: item)
        #expect(item.keyEquivalent == "b")
        #expect(manager.hasShortcut(AppDelegate.tabSidebarShortcut))
    }

    @Test func toggleIsOnlyHandledByRegularTerminalWindows() {
        let selector = #selector(TerminalController.toggleTabSidebar(_:))
        #expect(TerminalController.instancesRespond(to: selector))
        #expect(!QuickTerminalController.instancesRespond(to: selector))
        #expect(!AppDelegate.instancesRespond(to: selector))
    }

    @MainActor @Test func mainMenuRoutesCmdBThroughResponderChain() throws {
        let menu = try #require(NSApp.mainMenu)
        let item = try #require(findItem(in: menu, action: #selector(TerminalController.toggleTabSidebar(_:))))
        #expect(item.target == nil)
    }

    @MainActor private func findItem(in menu: NSMenu, action: Selector) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = findItem(in: submenu, action: action) { return found }
        }
        return nil
    }
}
