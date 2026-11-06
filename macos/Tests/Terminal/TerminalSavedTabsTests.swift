import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct TerminalTabLifecycleTests {
    @Test func snoozeIsExclusiveAndDeadlineDriven() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = TerminalTabLifecycle()
        state.pin(true)
        #expect(state.isPinned && state.isSaved)
        let rejected = state.snooze(until: now, now: now)
        #expect(!rejected)
        #expect(state.isPinned)
        let snoozed = state.snooze(until: now.addingTimeInterval(60), now: now)
        #expect(snoozed)
        #expect(!state.isPinned && state.isSnoozed && state.isSaved)
        let early = state.wake(now: now, onlyIfDue: true)
        #expect(!early)
        let due = state.wake(now: now.addingTimeInterval(60), onlyIfDue: true)
        #expect(due)
        #expect(!state.isSaved)
        #expect(state.wokeAt == now.addingTimeInterval(60))
        state.pin(true)
        #expect(state.wokeAt == nil)
        #expect(state.snoozedUntil == nil)
        state.pin(false)
        #expect(!state.isSaved)
    }

    @Test func pinningSnoozedTabWakesAndPinsIt() {
        var state = TerminalTabLifecycle()
        let snoozed = state.snooze(until: .distantFuture)
        #expect(snoozed)
        state.pin(true)
        #expect(state.isPinned)
        #expect(!state.isSnoozed)
    }
}

struct TerminalSnoozePresetTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func mondayMeansFollowingWeekEvenBeforeMorning() throws {
        let calendar = calendar("UTC")
        let monday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 7)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9)))
        #expect(TerminalSnoozePreset.monday.deadline(now: monday, calendar: calendar) == expected)
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23)))
        let nextMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        #expect(TerminalSnoozePreset.monday.deadline(now: sunday, calendar: calendar) == nextMorning)
    }

    @Test func calendarDaysAndElapsedHoursHandleDaylightSaving() throws {
        let calendar = calendar("America/New_York")
        let before = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9)))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
        #expect(TerminalSnoozePreset.tomorrow.deadline(now: before, calendar: calendar) == tomorrow)
        #expect(tomorrow.timeIntervalSince(before) == 23 * 3600)
        #expect(TerminalSnoozePreset.hour.deadline(now: before, calendar: calendar)?.timeIntervalSince(before) == 3600)
        #expect(TerminalSnoozePreset.tomorrow.deadline(now: before, morningHour: 24, calendar: calendar) == nil)
    }
}

struct TerminalSavedTabArchiveTests {
    @MainActor @Test func explicitClosePersistsRemovalWithoutChangingOtherRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved-tabs.json")
        let pinned = UUID()
        let snoozed = UUID()
        let firstGroup = UUID()
        let secondGroup = UUID()
        let archive = TerminalSavedTabArchive(tabs: [
            .init(id: pinned, groupID: firstGroup, order: 0, selected: true,
                lifecycle: .init(isPinned: true), terminal: Data("pinned-layout".utf8),
                frame: "{{0,0},{800,600}}", sidebarWidth: 280, snoozedExpanded: false),
            .init(id: snoozed, groupID: secondGroup, order: 1, selected: false,
                lifecycle: .init(snoozedUntil: .distantFuture), terminal: Data("split-layout".utf8),
                frame: "{{10,10},{900,700}}", sidebarWidth: 320, snoozedExpanded: true)
        ])
        try JSONEncoder().encode(archive).write(to: url)
        let store = TerminalSavedTabs(url: url)
        #expect(store.contains(pinned))
        store.forget(pinned)
        let persisted = try JSONDecoder().decode(TerminalSavedTabArchive.self, from: Data(contentsOf: url))
        #expect(persisted.tabs.count == 1)
        let tab = try #require(persisted.tabs.first)
        #expect(tab.id == snoozed)
        #expect(tab.groupID == secondGroup)
        #expect(tab.lifecycle.snoozedUntil == .distantFuture)
        #expect(tab.terminal == Data("split-layout".utf8))
        #expect(tab.snoozedExpanded)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

struct TerminalDormantRestoreTests {
    @MainActor @Test func savedGroupRestoresSplitFocusAndRetainsOrderThroughQuit() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved-tabs.json")
        let groupID = UUID()
        let tabIDs = [UUID(), UUID(), UUID()]
        var records: [TerminalSavedTabArchive.Tab] = []
        var focusedID: UUID?
        let encoder = JSONEncoder()
        encoder.userInfo[.durableTabSnapshot] = true
        for (index, id) in tabIDs.enumerated() {
            let left = Ghostty.SurfaceView(app, deferTerminal: true)
            let right = Ghostty.SurfaceView(app, deferTerminal: true)
            let tree = SplitTree<Ghostty.SurfaceView>(root: .split(.init(direction: .horizontal, ratio: 0.5,
                left: .leaf(view: left), right: .leaf(view: right))), zoomed: nil)
            let snapshot = TerminalRestorableState.InternalState(
                focusedSurface: right.id.uuidString, surfaceTree: tree, effectiveFullscreenMode: nil,
                tabColor: TerminalTabColor.blue, titleOverride: "Saved tab \(index)")
            if index == 1 { focusedID = right.id }
            records.append(.init(id: id, groupID: groupID, order: index, selected: index == 1,
                lifecycle: .init(isPinned: true), terminal: try encoder.encode(snapshot),
                frame: "{{0,0},{900,700}}", sidebarWidth: 280, snoozedExpanded: false))
        }
        try JSONEncoder().encode(TerminalSavedTabArchive(tabs: records)).write(to: url)
        let store = TerminalSavedTabs(url: url)
        store.restore(ghostty)
        let controllers = TerminalController.all.filter { tabIDs.contains($0.savedTabID) }
        defer {
            store.terminate()
            controllers.forEach { $0.window?.close() }
        }
        let selected = try #require(controllers.first { $0.savedTabID == tabIDs[1] })
        let window = try #require(selected.window)
        let deadline = Date().addingTimeInterval(3)
        while (window.firstResponder as? Ghostty.SurfaceView)?.id != focusedID || selected.focusedSurface?.id != focusedID,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((window.firstResponder as? Ghostty.SurfaceView)?.id == focusedID)
        #expect(selected.focusedSurface?.id == focusedID)
        store.terminate()
        for controller in controllers {
            controller.window?.close()
            store.forget(controller.savedTabID)
        }
        let saved = try JSONDecoder().decode(TerminalSavedTabArchive.self, from: Data(contentsOf: url))
        let group = saved.tabs.filter { $0.groupID == groupID }.sorted { $0.order < $1.order }
        #expect(group.map(\.id) == tabIDs)
        #expect(group.map(\.order) == [0, 1, 2])
        #expect(group.filter(\.selected).map(\.id) == [tabIDs[1]])
        let decoder = JSONDecoder()
        decoder.userInfo[.durableTabSnapshot] = true
        for record in group {
            let state = try decoder.decode(TerminalRestorableState.self, from: record.terminal)
            #expect(state.effectiveFullscreenMode == nil)
        }
    }

    @MainActor @Test func closeRightMenuFollowsSidebarOrderAndProtectsSavedTabs() throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let ordinary = TerminalController(ghostty, withSurfaceTree: .init(view: Ghostty.SurfaceView(app, deferTerminal: true)))
        let pinned = TerminalController(ghostty, withSurfaceTree: .init(view: Ghostty.SurfaceView(app, deferTerminal: true)))
        defer { ordinary.window?.close(); pinned.window?.close() }
        let first = try #require(ordinary.window)
        let second = try #require(pinned.window)
        first.orderFront(nil)
        first.addTabbedWindow(second, ordered: .above)
        ordinary.reconnectSidebarModel()
        pinned.reconnectSidebarModel()
        pinned.sidebarItem.lifecycle.pin(true)
        let menu = NSMenuItem(title: "Close Tabs to the Right", action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        #expect(pinned.validateMenuItem(menu))
        #expect(!ordinary.validateMenuItem(menu))
        ordinary.sidebarItem.lifecycle.pin(true)
        #expect(!pinned.validateMenuItem(menu))
    }

    @MainActor @Test func staleWindowFocusNotificationDoesNotStartDormantTerminal() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let pane = Ghostty.SurfaceView(app, deferTerminal: true)
        let controller = TerminalController(ghostty, withSurfaceTree: .init(view: pane))
        let window = try #require(controller.window)
        defer { window.close() }
        window.orderOut(nil)
        try #require(!window.isKeyWindow)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: ()) }
        }
        #expect(pane.surfaceModel == nil)
    }

    @MainActor @Test func splitSnapshotPreservesLayoutWithoutStartingUnvisitedPanes() throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        let left = Ghostty.SurfaceView(app, deferTerminal: true)
        let right = Ghostty.SurfaceView(app, deferTerminal: true)
        left.pwd = "/tmp"
        right.pwd = "/"
        left.titleOverride = "Left pane"
        right.titleOverride = "Right pane"
        let tree = SplitTree<Ghostty.SurfaceView>(root: .split(.init(direction: .horizontal, ratio: 0.37,
            left: .leaf(view: left), right: .leaf(view: right))), zoomed: nil)
        let snapshot = TerminalRestorableState.InternalState(
            focusedSurface: right.id.uuidString, surfaceTree: tree, effectiveFullscreenMode: nil,
            tabColor: TerminalTabColor.blue, titleOverride: "Saved split")
        let encoder = JSONEncoder()
        encoder.userInfo[.durableTabSnapshot] = true
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.userInfo[.durableTabSnapshot] = true
        let restored = try decoder.decode(TerminalRestorableState.InternalState<Ghostty.SurfaceView>.self, from: data)
        let panes = Array(restored.surfaceTree)
        #expect(panes.map(\.id) == [left.id, right.id])
        #expect(panes.map(\.pwd) == ["/tmp", "/"])
        #expect(panes.map(\.title) == ["Left pane", "Right pane"])
        #expect(restored.focusedSurface == right.id.uuidString)
        #expect(restored.tabColor == .blue)
        #expect(restored.titleOverride == "Saved split")
        #expect(panes.allSatisfy { $0.surfaceModel == nil })
        guard case .split(let split) = restored.surfaceTree.root else {
            Issue.record("Lost the restored split layout")
            return
        }
        #expect(split.ratio == 0.37)
        let contentSize = NSSize(width: 228, height: 586)
        panes[0].sizeDidChange(contentSize)
        panes[0].startDeferredTerminal()
        let surface = try #require(panes[0].surface)
        let size = ghostty_surface_size(surface)
        let expectedSize = panes[0].convertToBacking(contentSize)
        #expect(size.width_px == UInt32(expectedSize.width))
        #expect(size.height_px == UInt32(expectedSize.height))
        #expect(panes[1].surfaceModel == nil)
        panes[0].startDeferredTerminal()
        #expect(panes[1].surfaceModel == nil)
    }
}

struct TerminalAgentResumeTests {
    @Test func preserveSupportedSettingsButNeverReplayPromptOrSelector() {
        #expect(TerminalAgentIntegration.savedOptions(kind: .claude,
            arguments: ["--model", "opus", "--permission-mode=plan", "--resume", "old", "private prompt"]) ==
            ["--model", "opus", "--permission-mode", "plan"])
        #expect(TerminalAgentIntegration.savedOptions(kind: .codex,
            arguments: ["--profile", "work", "--sandbox", "workspace-write", "resume", "old", "private prompt"]) ==
            ["--profile", "work", "--sandbox", "workspace-write"])
        #expect(TerminalAgentIntegration.savedOptions(kind: .pi,
            arguments: ["--provider", "openai-codex", "--thinking", "high", "--session", "/old.jsonl", "private prompt"]) ==
            ["--provider", "openai-codex", "--thinking", "high"])
        #expect(TerminalAgentIntegration.savedOptions(kind: .codex,
            arguments: ["-c", "model_reasoning_effort=\"xhigh\"", "--model", "test"]) ==
            ["--config", "model_reasoning_effort=\"xhigh\"", "--model", "test"])
        #expect(TerminalAgentIntegration.savedOptions(kind: .claude, arguments: ["--resume"]) == [])
        #expect(TerminalAgentIntegration.savedOptions(kind: .claude,
            arguments: ["-r", "--model", "opus"]) == ["--model", "opus"])
        #expect(TerminalAgentIntegration.savedOptions(kind: .pi, arguments: ["-r"]) == [])
        #expect(TerminalAgentIntegration.savedOptions(kind: .pi, arguments: [""]) == [])
    }

    @Test func rejectNoninteractiveOrUnsupportedLaunches() {
        let cases: [(TerminalAgentSession.Kind, [String])] = [
            (.claude, ["-p", "prompt"]), (.pi, ["--mode", "rpc"]),
            (.codex, ["exec", "prompt"]), (.codex, ["login"]),
            (.claude, ["--settings", "private.json"]), (.pi, ["--no-extensions"]),
            (.pi, ["--api-key", "secret"]), (.claude, ["--model", "bad\ninput"]),
            (.codex, ["--config", "model_providers.private.api_key=\"secret\""]),
            (.codex, ["--unknown-option", "value"])
        ]
        for (kind, arguments) in cases {
            #expect(TerminalAgentIntegration.savedOptions(kind: kind, arguments: arguments) == nil)
        }
    }

    @Test func resumeUsesExactSessionWithoutAdditionalPrompt() {
        let id = "00000000-0000-4000-8000-000000000001"
        let base = TerminalAgentSession(kind: .codex, session: id, executable: "/opt/bin/codex",
            arguments: ["--model", "test-model"], environment: [:], directory: "/tmp/project")
        #expect(base.resumeArguments == ["--model", "test-model", "resume", id])
        var claude = base
        claude.kind = .claude
        #expect(claude.resumeArguments == ["--model", "test-model", "--resume", id])
        var pi = base
        pi.kind = .pi
        pi.session = "/tmp/project with spaces/session.jsonl"
        #expect(pi.resumeArguments == ["--model", "test-model", "--session", "/tmp/project with spaces/session.jsonl"])
    }

    @Test func missingOrReplacedPiConversationCannotAutoResume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let id = "00000000-0000-4000-8000-000000000001"
        let session = TerminalAgentSession(kind: .pi, session: file.path, executable: "/bin/pi",
            arguments: [], environment: [:], directory: directory.path, nativeSessionID: id)
        #expect(!session.hasExistingConversation)
        try Data("{\"type\":\"session\",\"id\":\"\(id)\"}\n".utf8).write(to: file)
        #expect(session.hasExistingConversation)
        let alias = directory.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        var linkedSession = session
        linkedSession.session = alias.path
        #expect(linkedSession.hasExistingConversation)
        try Data("{\"type\":\"session\",\"id\":\"00000000-0000-4000-8000-000000000002\"}\n".utf8).write(to: file)
        #expect(!session.hasExistingConversation)
        try Data("corrupted session\n".utf8).write(to: file)
        #expect(!session.hasExistingConversation)
    }

    @Test func rejectTerminalControlCharactersBeforeInjectingResumeCommand() {
        var session = TerminalAgentSession(kind: .pi, session: "/tmp/session.jsonl", executable: "/bin/pi",
            arguments: [], environment: [:], directory: "/tmp", nativeSessionID: "00000000-0000-4000-8000-000000000001")
        #expect(session.command(helper: "/Applications/Ghostty.app/Contents/MacOS/ghostty") != nil)
        session.session = "/tmp/session\u{15}; touch /tmp/not-safe\n"
        #expect(session.command(helper: "/bin/ghostty") == nil)
        session.session = "/tmp/session.jsonl"
        session.environment["PI_AGENT_DIR"] = "/tmp/bad\rpath"
        #expect(session.command(helper: "/bin/ghostty") == nil)
    }
}
