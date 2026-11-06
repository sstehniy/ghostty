import AppKit
import Combine

struct TerminalTabLifecycle: Codable, Equatable {
    var isPinned = false
    var snoozedUntil: Date?
    var wokeAt: Date?

    var isSnoozed: Bool { snoozedUntil != nil }
    var isSaved: Bool { isPinned || isSnoozed }

    mutating func pin(_ pinned: Bool) {
        isPinned = pinned
        snoozedUntil = nil
        wokeAt = nil
    }

    mutating func snooze(until: Date, now: Date = Date()) -> Bool {
        guard until > now else { return false }
        isPinned = false
        snoozedUntil = until
        wokeAt = nil
        return true
    }

    @discardableResult
    mutating func wake(now: Date = Date(), onlyIfDue: Bool = false) -> Bool {
        guard let until = snoozedUntil, !onlyIfDue || until <= now else { return false }
        snoozedUntil = nil
        wokeAt = now
        return true
    }
}

enum TerminalSnoozePreset: String, CaseIterable {
    case hour = "In 1 hour"
    case tomorrow = "Tomorrow morning"
    case monday = "Next Monday"

    func deadline(now: Date = Date(), morningHour: Int = 9, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(morningHour) else { return nil }
        if self == .hour { return now.addingTimeInterval(3600) }
        let today = calendar.startOfDay(for: now)
        var days = 1
        if self == .monday {
            days = (9 - calendar.component(.weekday, from: today)) % 7
            if days == 0 { days = 7 }
        }
        guard let day = calendar.date(byAdding: .day, value: days, to: today) else { return nil }
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day)
    }
}

extension CodingUserInfoKey {
    static let durableTabSnapshot = CodingUserInfoKey(rawValue: "ghostty.durableTabSnapshot")!
}

struct TerminalSavedTabArchive: Codable {
    var version = 1
    var tabs: [Tab] = []

    struct Tab: Codable, Identifiable {
        var id: UUID
        var groupID: UUID
        var order: Int
        var selected: Bool
        var lifecycle: TerminalTabLifecycle
        var terminal: Data
        var frame: String
        var sidebarWidth: Double
        var snoozedExpanded: Bool
    }
}

/// Explicit saves are independent of AppKit's optional window restoration.
final class TerminalSavedTabs {
    static let shared = TerminalSavedTabs()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(UserDefaults.ghosttySuite ?? Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
    }

    let url: URL
    private(set) var archive: TerminalSavedTabArchive
    private(set) var hasRestored = false
    private(set) var isRestoring = false
    private(set) var isTerminating = false
    private var timer: Timer?
    private var lastWritten: Data?
    private var closedIDs: Set<UUID> = []
    private var loadFailure: Error?

    init(url: URL = TerminalSavedTabs.directory.appendingPathComponent("saved-tabs.json")) {
        self.url = url
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TerminalSavedTabArchive.self, from: data)
            guard decoded.version == 1,
                  Set(decoded.tabs.map(\.id)).count == decoded.tabs.count else {
                throw CocoaError(.coderReadCorrupt)
            }
            archive = decoded
            lastWritten = data
        } catch {
            archive = .init()
            if FileManager.default.fileExists(atPath: url.path) {
                loadFailure = error
                AppDelegate.logger.error("Cannot load saved tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit { timer?.invalidate() }

    func contains(_ id: UUID) -> Bool {
        archive.tabs.contains { $0.id == id }
    }

    func restore(_ ghostty: Ghostty.App) {
        guard !hasRestored else { return }
        isRestoring = true
        if let loadFailure { showSaveError(loadFailure) }
        let saved = archive.tabs
        let groups = Dictionary(grouping: saved, by: \.groupID)
        var restoreFailures = 0
        for (groupID, records) in groups {
            var parent = TerminalController.all.first { $0.savedGroupID == groupID }?.window
            let existingSelection = parent?.tabGroup?.selectedWindow ?? parent
            var fullscreenMode: FullscreenMode?
            var restored: [(TerminalSavedTabArchive.Tab, TerminalController)] = []
            for record in records.sorted(by: { $0.order < $1.order }) {
                do {
                    let decoder = JSONDecoder()
                    decoder.userInfo[.durableTabSnapshot] = true
                    let state = try decoder.decode(TerminalRestorableState.self, from: record.terminal)
                    let controller = TerminalController(ghostty, withSurfaceTree: state.surfaceTree)
                    fullscreenMode = fullscreenMode ?? state.effectiveFullscreenMode
                    controller.savedTabID = record.id
                    controller.savedGroupID = groupID
                    controller.sidebarItem.lifecycle = record.lifecycle
                    controller.titleOverride = state.titleOverride
                    if let kind = controller.surfaceTree.compactMap({ $0.agentRestoration?.session?.kind }).first {
                        controller.sidebarItem.icon = TerminalAppIcon(rawValue: kind.rawValue) ?? .terminal
                    }
                    guard let window = controller.window else { throw TerminalRestoreError.windowDidNotLoad }
                    (window as? TerminalWindow)?.tabColor = state.tabColor ?? .none
                    controller.sidebarModel.persistentID = groupID
                    controller.sidebarModel.snoozedExpanded = record.snoozedExpanded
                    controller.sidebarModel.setWidth(CGFloat(record.sidebarWidth), persist: false)
                    controller.sidebarModel.setVisible(true, persist: false)
                    if let focused = state.focusedSurface,
                       let view = controller.surfaceTree.first(where: { $0.id.uuidString == focused }) {
                        controller.focusedSurface = view
                        TerminalWindowRestoration.restoreFocus(to: view, inWindow: window)
                    }
                    if let existing = parent {
                        window.tabbingMode = .preferred
                        let last = existing.tabGroup?.windows.last ?? existing
                        if last.addTabbedWindowSafely(window, ordered: .above) {
                            TerminalController.moveTab(window, to: record.order)
                        } else {
                            controller.showWindowSafely(nil)
                        }
                    } else {
                        parent = window
                        let frame = NSRectFromString(record.frame)
                        if frame.width >= 200, frame.height >= 100 { window.setFrame(frame, display: false) }
                        window.constrainToScreen()
                    }
                    controller.reconnectSidebarModel()
                    restored.append((record, controller))
                } catch {
                    restoreFailures += 1
                    AppDelegate.logger.error("Cannot restore saved tab: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let first = restored.first else { continue }
            let selection = restored.first { $0.0.selected }
            if let selection {
                selection.1.showWindowSafely(nil)
            } else if let existingSelection {
                existingSelection.makeKeyAndOrderFront(nil)
            } else {
                _ = TerminalController.newTab(ghostty, from: first.1.window)
            }
            if let mode = fullscreenMode {
                let controller = selection?.1 ?? first.1
                DispatchQueue.main.async { [weak controller] in
                    guard let controller, controller.window?.isVisible == true,
                          controller.fullscreenStyle?.isFullscreen != true else { return }
                    controller.toggleFullscreen(mode: mode)
                }
            }
        }
        if restoreFailures > 0 {
            let alert = NSAlert()
            alert.messageText = "Some Saved Tabs Could Not Be Restored"
            alert.informativeText = "\(restoreFailures) saved tabs remain in \(url.path). Their records have not been removed."
            alert.runModal()
        }
        isRestoring = false
        hasRestored = true
        for controller in TerminalController.all {
            controller.sidebarModel.wakeDueTabs()
            if controller.window?.isKeyWindow == true { controller.resumeSavedTabIfNeeded() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        guard hasRestored, !isRestoring, !isTerminating else { return }
        for controller in TerminalController.all { controller.sidebarModel.wakeDueTabs() }
        TerminalAgentIntegration.refresh(TerminalController.all.flatMap { Array($0.surfaceTree) }) { [weak self] in
            self?.save()
        }
    }

    func forget(_ id: UUID) {
        guard !isTerminating else { return }
        closedIDs.insert(id)
        archive.tabs.removeAll { $0.id == id }
        writeArchive()
    }

    func save() {
        guard hasRestored, !isRestoring, !isTerminating else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.userInfo[.durableTabSnapshot] = true
            var records: [TerminalSavedTabArchive.Tab] = []
            for controller in TerminalController.all {
                guard !closedIDs.contains(controller.savedTabID), controller.sidebarItem.lifecycle.isSaved,
                      let window = controller.window else { continue }
                let model = controller.sidebarModel
                let issue = controller.surfaceTree.compactMap { $0.agentRestoration?.issue }.first
                if controller.sidebarItem.restorationIssue != issue { controller.sidebarItem.restorationIssue = issue }
                records.append(.init(
                    id: controller.savedTabID, groupID: model.persistentID,
                    order: model.tabs.firstIndex { $0.window === window } ?? 0,
                    selected: window.tabGroup?.selectedWindow === window || window.isKeyWindow,
                    lifecycle: controller.sidebarItem.lifecycle,
                    terminal: try encoder.encode(TerminalRestorableState(from: controller)),
                    frame: NSStringFromRect(window.frame), sidebarWidth: Double(model.width),
                    snoozedExpanded: model.snoozedExpanded))
            }
            // Preserve failed restores so a decode error cannot erase the only copy.
            let openIDs = Set(TerminalController.all.map(\.savedTabID))
            records += archive.tabs.filter { !openIDs.contains($0.id) && !closedIDs.contains($0.id) }
            archive.tabs = records.sorted { $0.id.uuidString < $1.id.uuidString }
            writeArchive()
        } catch {
            showSaveError(error)
        }
    }

    func terminate() {
        guard !isTerminating else { return }
        TerminalAgentIntegration.refreshSynchronously(TerminalController.all.flatMap { Array($0.surfaceTree) })
        save()
        isTerminating = true
        timer?.invalidate()
    }

    private func writeArchive() {
        if let loadFailure {
            showSaveError(loadFailure)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            guard data != lastWritten else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastWritten = data
        } catch {
            showSaveError(error)
        }
    }

    private var reportedSaveError = false
    private func showSaveError(_ error: Error) {
        AppDelegate.logger.error("Cannot save pinned or snoozed tabs: \(error.localizedDescription, privacy: .public)")
        guard !reportedSaveError else { return }
        reportedSaveError = true
        let alert = NSAlert()
        alert.messageText = "Cannot Save Tabs"
        alert.informativeText = "Pinned and snoozed tabs may not survive quitting. \(error.localizedDescription)"
        alert.runModal()
    }
}
