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
    @Test func dropIndexUsesFullOrder() {
        let full = ["a", "b", "c", "d", "e"]

        // Search shows only "b" and "e"; dropping onto "e" lands at e's full index,
        // not at the filtered index 1.
        #expect(TerminalTabSidebarModel.fullOrderIndex(forDropOnto: "e", in: full) == 4)
        #expect(TerminalTabSidebarModel.fullOrderIndex(forDropOnto: "b", in: full) == 1)
        #expect(TerminalTabSidebarModel.fullOrderIndex(forDropOnto: "z", in: full) == nil)
    }

    @Test func dropAfterLastVisibleRow() {
        let full = ["a", "b", "c", "d", "e"]
        #expect(TerminalTabSidebarModel.fullOrderIndex(forDropAfterLastOf: ["a", "c"], in: full) == 2)
        #expect(TerminalTabSidebarModel.fullOrderIndex(forDropAfterLastOf: [String](), in: full) == nil)
    }

    @Test func reorderTargetFollowsDragDistance() {
        let step = TerminalTabSidebarRow.height + TerminalTabSidebarView.rowSpacing
        // Less than half a row stays put; past half a row moves one slot.
        #expect(TerminalTabSidebarView.targetIndex(from: 1, offset: step * 0.4, count: 5) == 1)
        #expect(TerminalTabSidebarView.targetIndex(from: 1, offset: step * 0.6, count: 5) == 2)
        #expect(TerminalTabSidebarView.targetIndex(from: 1, offset: step * 3, count: 5) == 4)
        #expect(TerminalTabSidebarView.targetIndex(from: 3, offset: -step * 2, count: 5) == 1)
        // Clamped to the list.
        #expect(TerminalTabSidebarView.targetIndex(from: 1, offset: step * 10, count: 5) == 4)
        #expect(TerminalTabSidebarView.targetIndex(from: 1, offset: -step * 10, count: 5) == 0)
    }

    @Test func reorderDisplacesRowsBetweenStartAndTarget() {
        // Dragging row 1 down to 3: rows 2 and 3 move up a slot.
        let down = (0..<5).map { TerminalTabSidebarView.displacement(ofRowAt: $0, start: 1, target: 3) }
        #expect(down == [0, 0, -1, -1, 0])

        // Dragging row 3 up to 1: rows 1 and 2 move down a slot.
        let up = (0..<5).map { TerminalTabSidebarView.displacement(ofRowAt: $0, start: 3, target: 1) }
        #expect(up == [0, 1, 1, 0, 0])

        let none = (0..<5).map { TerminalTabSidebarView.displacement(ofRowAt: $0, start: 2, target: 2) }
        #expect(none == [0, 0, 0, 0, 0])
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
