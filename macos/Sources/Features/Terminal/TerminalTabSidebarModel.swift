import AppKit
import Combine

// MARK: Item

/// The presentation state for a single tab in the tab sidebar. Each terminal controller
/// owns one item; the row identity in the sidebar is the tab's window.
///
/// This is intentionally separate from the controller so that title and directory
/// changes only re-render the sidebar row and not the terminal view.
final class TerminalTabSidebarItem: ObservableObject {
    /// The title as displayed on the tab, including any manually assigned title.
    @Published var title: String = ""

    /// The working directory of the tab's last focused pane, if known.
    @Published var directory: String?

    /// The icon of the foreground program in the tab's last focused pane.
    @Published var icon: TerminalAppIcon = .terminal
    @Published var remoteLabel: String?

    /// The user-assigned tab color.
    @Published var tabColor: TerminalTabColor = .none

    /// The keyboard shortcut label for selecting this tab (e.g. "⌘1").
    @Published var shortcut: String?

    @Published var lifecycle = TerminalTabLifecycle()
    @Published var restorationIssue: String?

    /// Returns the foreground process of the tab's last focused pane. Called on the
    /// main thread by the icon sampler.
    var foregroundPID: () -> pid_t? = { nil }
    var remoteDirectory: () -> String? = { nil }

    /// The directory for display, with the home directory abbreviated as `~`.
    var displayDirectory: String? {
        directory.map { Self.abbreviate(path: $0) }
    }

    /// Abbreviates the home directory prefix of a path as `~`. Only whole path
    /// components are abbreviated, so `/Users/foobar` is unchanged for `/Users/foo`.
    static func abbreviate(
        path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home || path == home + "/" { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: Preferences

/// Persisted sidebar defaults. Open window groups keep their own state; these values
/// seed new and restored window groups.
struct TerminalTabSidebarPreferences {
    static let visibleKey = "TerminalTabSidebarVisible"
    static let widthKey = "TerminalTabSidebarWidth"

    static let defaultWidth: CGFloat = 280
    static let minimumWidth: CGFloat = 200
    static let maximumWidth: CGFloat = 520

    let defaults: UserDefaults

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
    }

    var isVisible: Bool {
        get { defaults.bool(forKey: Self.visibleKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.visibleKey) }
    }

    var width: CGFloat {
        get {
            guard let value = defaults.object(forKey: Self.widthKey) as? Double else { return Self.defaultWidth }
            return Self.clamp(width: CGFloat(value))
        }
        nonmutating set { defaults.set(Double(Self.clamp(width: newValue)), forKey: Self.widthKey) }
    }

    static func clamp(width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }
}

// MARK: Model

/// Sidebar state shared by every tab in one native window tab group.
///
/// Membership and order are always read from `NSWindowTabGroup.windows`; the model
/// never stores its own tab list. Visibility, width, and search text are shared by all
/// tabs in the group so switching tabs preserves them.
final class TerminalTabSidebarModel: ObservableObject {
    /// One row in the sidebar. The window is the row identity.
    struct Tab: Identifiable {
        let id: ObjectIdentifier
        weak var window: NSWindow?
        let item: TerminalTabSidebarItem

        init(window: NSWindow, item: TerminalTabSidebarItem) {
            self.id = ObjectIdentifier(window)
            self.window = window
            self.item = item
        }
    }

    /// Posted (object: model) when the windows of the observed tab group change.
    static let membershipDidChange = Notification.Name("TerminalTabSidebarMembershipDidChange")

    @Published private(set) var isVisible: Bool
    @Published private(set) var width: CGFloat
    @Published var searchText: String = ""
    @Published var snoozedExpanded = false {
        didSet { TerminalSavedTabs.shared.save() }
    }
    var persistentID = UUID()

    /// All tabs in tab-group order.
    @Published private(set) var tabs: [Tab] = []

    /// The selected tab of the group.
    @Published private(set) var selectedID: ObjectIdentifier?

    /// The row highlighted by keyboard navigation from the search field.
    @Published var keyboardHighlightID: ObjectIdentifier?

    /// The tab group this model is bound to. Nil until bound.
    private(set) weak var tabGroup: NSWindowTabGroup?

    /// Shown before the model is bound to a tab group so a new window immediately
    /// displays its own row.
    weak var provisionalWindow: NSWindow? {
        didSet { refresh() }
    }

    let preferences: TerminalTabSidebarPreferences

    /// Maps a window in the group to its sidebar item. Windows without an item
    /// (non-terminal windows) are omitted.
    var itemProvider: (NSWindow) -> TerminalTabSidebarItem? = { window in
        (window.windowController as? BaseTerminalController)?.sidebarItem
    }

    private var windowsObservation: NSKeyValueObservation?
    private var selectionObservation: NSKeyValueObservation?
    private var itemObservations: [AnyCancellable] = []
    private var iconTimer: Timer?
    private var snoozeTimer: Timer?

    /// Seconds between icon samples while the sidebar is visible.
    static let iconSampleInterval: TimeInterval = 2

    /// Creates a model for a new window group.
    ///
    /// - Parameters:
    ///   - preferences: The persisted last-used state.
    ///   - configuredLayout: The `macos-tab-layout` configuration. When set it decides
    ///     the initial layout; otherwise the last-used layout is restored.
    init(
        preferences: TerminalTabSidebarPreferences = .init(),
        configuredLayout: Ghostty.MacOSTabLayout? = nil
    ) {
        self.preferences = preferences
        self.isVisible = Self.initialVisibility(configuredLayout: configuredLayout, lastUsed: preferences.isVisible)
        self.width = preferences.width
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged),
            name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(clockChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Whether a new window group starts with the sidebar (vertical tabs).
    static func initialVisibility(configuredLayout: Ghostty.MacOSTabLayout?, lastUsed: Bool) -> Bool {
        switch configuredLayout {
        case .vertical: return true
        case .horizontal: return false
        case nil: return lastUsed
        }
    }

    /// Creates an unbound model that continues another group's visibility and width,
    /// used when a tab is moved into a new window.
    convenience init(continuing other: TerminalTabSidebarModel) {
        self.init(preferences: other.preferences)
        self.isVisible = other.isVisible
        self.width = other.width
        self.itemProvider = other.itemProvider
    }

    deinit {
        windowsObservation?.invalidate()
        selectionObservation?.invalidate()
        iconTimer?.invalidate()
        snoozeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Self.unregister(self)
    }

    // MARK: Visibility and Width

    /// Sets visibility. When `persist` is true this is a user choice that also becomes
    /// the default for new windows.
    func setVisible(_ visible: Bool, persist: Bool) {
        if persist { preferences.isVisible = visible }
        guard visible != isVisible else { return }
        isVisible = visible
        updateIconSampling()
    }

    /// Sets the width. `persist` should be true when a resize finishes.
    func setWidth(_ newWidth: CGFloat, persist: Bool) {
        let clamped = TerminalTabSidebarPreferences.clamp(width: newWidth)
        if width != clamped { width = clamped }
        if persist { preferences.width = clamped }
    }

    // MARK: Tab Group Binding

    private static var registry: [ObjectIdentifier: Weak<TerminalTabSidebarModel>] = [:]

    /// The model bound to the given tab group, if any.
    static func registered(for group: NSWindowTabGroup) -> TerminalTabSidebarModel? {
        let key = ObjectIdentifier(group)
        guard let model = registry[key]?.value else {
            registry.removeValue(forKey: key)
            return nil
        }

        // Guard against identifier reuse after a group was deallocated.
        guard model.tabGroup === group else {
            registry.removeValue(forKey: key)
            return nil
        }

        return model
    }

    private static func unregister(_ model: TerminalTabSidebarModel) {
        registry = registry.filter { $0.value.value != nil && $0.value.value !== model }
    }

    /// Bind this model to a tab group and observe its membership and selection.
    func bind(to group: NSWindowTabGroup) {
        guard tabGroup !== group else { return }

        windowsObservation?.invalidate()
        selectionObservation?.invalidate()
        Self.unregister(self)

        tabGroup = group
        provisionalWindow = nil
        Self.registry[ObjectIdentifier(group)] = .init(self)

        // NSWindowTabGroup documents both properties as key-value observable. We hop
        // to the next runloop turn because AppKit updates group state in several steps.
        windowsObservation = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                NotificationCenter.default.post(name: Self.membershipDidChange, object: self)
            }
        }
        selectionObservation = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshSelection() }
        }

        refresh()
        updateIconSampling()
    }

    /// Re-read membership, order, and selection from the tab group.
    func refresh() {
        let windows: [NSWindow]
        if let tabGroup {
            windows = tabGroup.windows
        } else if let provisionalWindow {
            windows = [provisionalWindow]
        } else {
            windows = []
        }

        let newTabs = windows.compactMap { window in
            itemProvider(window).map { Tab(window: window, item: $0) }
        }
        if newTabs.map(\.id) != tabs.map(\.id) || zip(newTabs, tabs).contains(where: { $0.item !== $1.item }) {
            tabs = newTabs
            observeItems()
        }

        if let keyboardHighlightID, !tabs.contains(where: { $0.id == keyboardHighlightID }) {
            self.keyboardHighlightID = nil
        }

        refreshSelection()
        scheduleSnoozeWake()
    }

    var pinnedTabs: [Tab] { tabs.filter { $0.item.lifecycle.isPinned } }
    var normalTabs: [Tab] { tabs.filter { !$0.item.lifecycle.isSaved } }
    var snoozedTabs: [Tab] { tabs.filter { $0.item.lifecycle.isSnoozed } }
    var navigationTabs: [Tab] { pinnedTabs + normalTabs }

    func setPinned(_ pinned: Bool, for tab: Tab) {
        tab.item.lifecycle.pin(pinned)
        lifecycleDidChange()
    }

    func snooze(_ tab: Tab, until: Date) {
        guard tab.item.lifecycle.snooze(until: until) else { return }
        lifecycleDidChange()
    }

    func wake(_ tab: Tab) {
        guard tab.item.lifecycle.wake() else { return }
        moveWokenTabToTop(tab)
        lifecycleDidChange()
    }

    func wakeDueTabs(now: Date = Date()) {
        var changed = false
        for tab in tabs where tab.item.lifecycle.wake(now: now, onlyIfDue: true) {
            moveWokenTabToTop(tab)
            changed = true
        }
        if changed { lifecycleDidChange() }
    }

    private func moveWokenTabToTop(_ tab: Tab) {
        guard let window = tab.window else { return }
        if let first = normalTabs.first(where: { $0.id != tab.id }),
           let index = tabs.firstIndex(where: { $0.id == first.id }),
           let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }), currentIndex > index {
            TerminalController.moveTab(window, to: index)
        }
    }

    private func lifecycleDidChange() {
        objectWillChange.send()
        scheduleSnoozeWake()
        NotificationCenter.default.post(name: Self.membershipDidChange, object: self)
        TerminalSavedTabs.shared.refresh()
    }

    @objc private func clockChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.wakeDueTabs()
            self?.scheduleSnoozeWake()
        }
    }

    private func scheduleSnoozeWake() {
        snoozeTimer?.invalidate()
        guard let deadline = tabs.compactMap({ $0.item.lifecycle.snoozedUntil }).min() else { return }
        let timer = Timer(fire: max(deadline, Date()), interval: 0, repeats: false) { [weak self] _ in
            self?.wakeDueTabs()
        }
        RunLoop.main.add(timer, forMode: .common)
        snoozeTimer = timer
    }

    /// Search results depend on each tab's title and directory, which publish on
    /// the items rather than on this model. Forward their changes while searching
    /// so the filtered list stays current.
    private func observeItems() {
        itemObservations = tabs.map { tab in
            Publishers.Merge3(
                tab.item.$title.dropFirst().map { _ in () },
                tab.item.$directory.dropFirst().map { _ in () },
                tab.item.$lifecycle.dropFirst().map { _ in () }
            )
            .sink { [weak self] in
                guard let self, self.isSearching else { return }
                self.objectWillChange.send()
            }
        }
    }

    func refreshSelection() {
        let selected = (tabGroup?.selectedWindow ?? provisionalWindow).map(ObjectIdentifier.init)
        if selected != selectedID { selectedID = selected }
    }

    // MARK: Search

    /// The tabs matching the current search, in full tab order.
    var filteredTabs: [Tab] {
        let candidates = isSearching ? navigationTabs + snoozedTabs : navigationTabs
        return candidates.filter { Self.matches(query: searchText, title: $0.item.title, directory: $0.item.displayDirectory) }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when every whitespace separated term of the query is found in the title
    /// or directory, ignoring case and diacritics.
    static func matches(query: String, title: String, directory: String?) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return terms.allSatisfy { term in
            title.range(of: term, options: options) != nil ||
                (directory?.range(of: term, options: options) != nil)
        }
    }

    /// Move the keyboard highlight within the filtered tabs.
    func moveKeyboardHighlight(by delta: Int) {
        let visible = filteredTabs
        guard !visible.isEmpty else {
            keyboardHighlightID = nil
            return
        }

        let currentID = keyboardHighlightID ?? selectedID
        let currentIndex = visible.firstIndex { $0.id == currentID }
        let next: Int
        if let currentIndex {
            next = min(max(currentIndex + delta, 0), visible.count - 1)
        } else {
            next = delta >= 0 ? 0 : visible.count - 1
        }
        keyboardHighlightID = visible[next].id
    }

    /// The tab that the return key should activate from the search field.
    var keyboardActivationTarget: Tab? {
        let visible = filteredTabs
        if let keyboardHighlightID, let tab = visible.first(where: { $0.id == keyboardHighlightID }) {
            return tab
        }
        return visible.first
    }

    // MARK: Reordering

    /// Resolve a section-local insertion slot against the native order after removing the source.
    func move(_ tab: Tab, to section: TerminalTabSidebarDrag.Section, at index: Int) {
        guard let window = tab.window, tabs.contains(where: { $0.id == tab.id }),
              tab.item.lifecycle.isSnoozed == (section == .snoozed) else { return }
        let sectionTabs: [Tab]
        switch section {
        case .pinned: sectionTabs = pinnedTabs
        case .regular: sectionTabs = normalTabs
        case .snoozed: sectionTabs = snoozedTabs
        }
        let destination = sectionTabs.filter { $0.id != tab.id }
        guard (0...destination.count).contains(index) else { return }
        let remaining = tabs.filter { $0.id != tab.id }
        let fullIndex: Int
        if index < destination.count,
           let before = remaining.firstIndex(where: { $0.id == destination[index].id }) {
            fullIndex = before
        } else if let last = destination.last,
                  let after = remaining.firstIndex(where: { $0.id == last.id }) {
            fullIndex = after + 1
        } else {
            fullIndex = section == .pinned ? 0 : remaining.count
        }

        TerminalController.moveTab(window, to: fullIndex)
        if section != .snoozed, tab.item.lifecycle.isPinned != (section == .pinned) {
            tab.item.lifecycle.pin(section == .pinned)
        }
        refresh()
        lifecycleDidChange()
    }

    // MARK: Icons

    /// Samples icons periodically only while the sidebar is shown. Hidden sidebars
    /// stop sampling entirely.
    private func updateIconSampling() {
        let shouldSample = isVisible && tabGroup != nil
        if shouldSample {
            guard iconTimer == nil else { return }
            let timer = Timer(timeInterval: Self.iconSampleInterval, repeats: true) { [weak self] _ in
                self?.sampleIcons()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            iconTimer = timer
            sampleIcons()
        } else {
            iconTimer?.invalidate()
            iconTimer = nil
        }
    }

    /// Sample foreground processes now. Process inspection runs off the main thread.
    func sampleIcons() {
        guard isVisible else { return }

        // Skip when no window of the group is on screen (minimized, hidden app, etc.)
        let onScreen = tabs.contains { $0.window?.occlusionState.contains(.visible) ?? false }
        guard onScreen else { return }

        var pidsByItem: [(TerminalTabSidebarItem, pid_t?)] = []
        for tab in tabs {
            pidsByItem.append((tab.item, tab.item.foregroundPID()))
        }

        let pids = Set(pidsByItem.compactMap(\.1))
        TerminalAppIconResolver.shared.resolve(pids: pids) { icons in
            for (item, pid) in pidsByItem {
                guard item.foregroundPID() == pid else { continue }
                let resolution = pid.flatMap { icons[$0] } ?? TerminalAppIconResolver.Resolution()
                if item.icon != resolution.icon { item.icon = resolution.icon }
                let label = resolution.remoteLabel(directory: item.remoteDirectory())
                if item.remoteLabel != label { item.remoteLabel = label }
            }
        }
    }
}
