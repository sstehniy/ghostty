import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

struct FloatPaneGeometryTests {
    @Test func normalizesAndClampsAfterContainerShrinks() {
        let size = CGSize(width: 1000, height: 600)
        let points = CGRect(x: 100, y: 60, width: 700, height: 420)
        let normalized = FloatPane.normalized(points, in: size)
        #expect(normalized == CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7))
        #expect(FloatPane.points(normalized, in: size) == points)
        let clamped = FloatPane.clamped(CGRect(x: 0.9, y: -0.2, width: 0.1, height: 0.1),
                                        in: CGSize(width: 400, height: 200))
        #expect(clamped == CGRect(x: 0.4, y: 0, width: 0.6, height: 0.6))
        #expect(FloatPane.clamped(normalized, in: CGSize(width: 100, height: 50)) ==
                CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func opensNearTopRightAndCascadesDownLeftThenWraps() {
        let size = CGSize(width: 1000, height: 600)
        let first = FloatPane.initialFrame(width: 0.4, height: 0.4, in: size, after: nil)
        #expect(abs(first.maxX - (1 - 0.024)) < 0.000001)
        #expect(abs(first.minY - 0.04) < 0.000001)
        #expect(first.width == 0.4 && first.height == 0.4)
        let next = FloatPane.initialFrame(width: 0.4, height: 0.4, in: size, after: first)
        #expect(abs(next.minX - (first.minX - 0.024)) < 0.000001)
        #expect(abs(next.minY - (first.minY + 0.04)) < 0.000001)
        #expect(FloatPane.initialFrame(width: 0.4, height: 0.4, in: size,
                                      after: CGRect(x: 0.01, y: 0.3, width: 0.4, height: 0.4)) == first)
        #expect(FloatPane.initialFrame(width: 0.4, height: 0.4, in: size,
                                      after: CGRect(x: 0.5, y: 0.59, width: 0.4, height: 0.4)) == first)
    }

    @Test func shiftResizeKeepsAspectRatioWithinBounds() {
        let size = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
        // Corner: follows the larger drag, anchored at the opposite corner.
        #expect(FloatResizeEdge.bottomRight.resizingKeepingAspect(frame, by: CGSize(width: 40, height: 100), in: size) ==
                CGRect(x: 100, y: 100, width: 600, height: 300))
        let topLeft = FloatResizeEdge.topLeft.resizingKeepingAspect(frame, by: CGSize(width: -40, height: 0), in: size)
        #expect(abs(topLeft.minX - 60) < 0.0001 && abs(topLeft.minY - 80) < 0.0001)
        #expect(abs(topLeft.width - 440) < 0.0001 && abs(topLeft.height - 220) < 0.0001)
        // Edge: the other dimension follows, top side stays fixed.
        #expect(FloatResizeEdge.right.resizingKeepingAspect(frame, by: CGSize(width: 100, height: 0), in: size) ==
                CGRect(x: 100, y: 100, width: 500, height: 250))
        // Clamped to the container without breaking the ratio.
        let big = FloatResizeEdge.bottomRight.resizingKeepingAspect(frame, by: CGSize(width: 2000, height: 0), in: size)
        #expect(big == CGRect(x: 100, y: 100, width: 900, height: 450))
        // Clamped to the minimum size (240 wide here), still 2:1.
        let small = FloatResizeEdge.bottomRight.resizingKeepingAspect(frame, by: CGSize(width: -1000, height: -1000), in: size)
        #expect(small == CGRect(x: 100, y: 100, width: 240, height: 120))
    }

    @Test func resizesFromOppositeAnchorsWithoutCrossingMinimumOrContainer() {
        let size = CGSize(width: 1000, height: 600)
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(FloatResizeEdge.topLeft.resizing(frame, by: CGSize(width: 999, height: 999), in: size) ==
                CGRect(x: 260, y: 280, width: 240, height: 120))
        #expect(FloatResizeEdge.bottomRight.resizing(frame, by: CGSize(width: 999, height: 999), in: size) ==
                CGRect(x: 100, y: 100, width: 900, height: 500))
    }
}

@MainActor
@Suite(.serialized)
struct FloatPaneControllerTests {
    private class Controller: TerminalController {
        let history = ExpiringUndoManager()
        override var undoManager: ExpiringUndoManager? { history }
        var onConfirmation: ((String) -> Void)?

        override func confirmCloseAsync(
            messageText: String,
            informativeText: String,
            confirmButtonTitle: String = "Close"
        ) async -> NSApplication.ModalResponse? {
            onConfirmation?(messageText)
            return .alertSecondButtonReturn
        }
    }

    private func makeController(live: Bool = false, command: String = "/bin/sleep 60") throws -> Controller {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let handle = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.fontSize = 17
        config.workingDirectory = FileManager.default.temporaryDirectory.path
        let treeSurface = Ghostty.SurfaceView(handle, baseConfig: config, deferTerminal: !live)
        let controller = Controller(app, withSurfaceTree: .init(view: treeSurface))
        let window = try #require(controller.window)
        window.setContentSize(CGSize(width: 1000, height: 600))
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        controller.focusedSurfaceDidChange(to: treeSurface)
        controller.layoutFloats(in: CGSize(width: 1000, height: 600))
        return controller
    }

    private func waitForLayout(_ condition: () -> Bool) async throws {
        // SwiftUI must commit pending view changes before focus can settle.
        try await Task.sleep(for: .milliseconds(50))
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func floatingPaneMenuLivesUnderViewWithoutDefaultShortcuts() throws {
        let viewMenu = try #require(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
        let floatMenu = try #require(viewMenu.item(withTitle: "Floating Panes")?.submenu)
        #expect(floatMenu.items.contains { ($0.representedObject as? String) == "new_float" })
        #expect(floatMenu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test func dockAndPopOutKeepTheSurfaceAndProcess() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let treeSurface = try #require(controller.surfaceTree.first)
        controller.performAction("new_float", on: treeSurface)
        let float = try #require(controller.floats.last?.surface)
        let processSurface = try #require(float.surface)
        let inherited = ghostty_surface_inherited_config(processSurface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        #expect(inherited.font_size == 17)
        let directory = String(cString: try #require(inherited.working_directory))
        #expect(URL(fileURLWithPath: directory).standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(BaseTerminalController.controller(owning: float) === controller)
        #expect(controller.toggleFloatDock())
        #expect(controller.floats.isEmpty)
        #expect(controller.surfaceTree.contains(float))
        #expect(float.surface == processSurface)
        #expect(controller.toggleFloatDock())
        #expect(controller.floats.first?.surface === float)
        #expect(float.surface == processSurface)
        #expect(controller.treeFocusSurface === treeSurface)
        #expect(controller.toggleFloatDock())
        #expect(float.surface == processSurface)
    }

    @Test func overlayMountsOverZoomedTreeAndHidingKeepsProcessAlive() async throws {
        let controller = try makeController(live: true)
        let window = try #require(controller.window)
        defer { window.close() }
        let tree = try #require(controller.surfaceTree.first)
        let sibling = Ghostty.SurfaceView(try #require(controller.ghostty.app), deferTerminal: true)
        controller.surfaceTree = try controller.surfaceTree.inserting(view: sibling, at: tree, direction: .right)
        controller.surfaceTree = .init(root: controller.surfaceTree.root, zoomed: .leaf(view: tree))
        let host = try #require(window.contentView)
        window.orderFront(nil)
        let float = try #require(controller.newFloat())
        let process = try #require(float.surface)
        host.layoutSubtreeIfNeeded()
        try await waitForLayout { float.window === window && window.firstResponder === float }
        #expect(controller.surfaceTree.isZoomed)
        #expect(float.window === window)
        #expect(tree.window === window)
        #expect(float.bounds.width > 240)
        #expect(window.firstResponder === float)
        controller.performAction("toggle_split_zoom", on: float)
        try await waitForLayout { !controller.surfaceTree.isZoomed && window.firstResponder === float }
        #expect(!controller.surfaceTree.isZoomed)
        #expect(window.firstResponder === float)
        #expect(float.window === window)
        window.makeFirstResponder(tree)
        try await waitForLayout { controller.focusedSurface === tree }
        #expect(controller.focusedSurface === tree)
        #expect(float.window === window)
        window.makeFirstResponder(float)
        try await waitForLayout { controller.focusedSurface === float }
        controller.toggleFloatsVisible()
        try await waitForLayout { float.window == nil && controller.focusedSurface === tree }
        #expect(float.window == nil)
        #expect(float.surface == process)
        #expect(controller.focusedSurface === tree)
        controller.toggleFloatsVisible()
        try await waitForLayout { float.window === window && window.firstResponder === float }
        #expect(float.window === window)
        #expect(float.surface == process)
    }

    @Test func paletteDismissalKeepsTheActionSelectedSurfaceFocused() async throws {
        let controller = try makeController(live: true)
        let window = try #require(controller.window)
        defer { window.close() }
        let tree = try #require(controller.surfaceTree.first)
        controller.focusSurface(tree)
        controller.commandPaletteIsShowing = true
        try await Task.sleep(for: .milliseconds(50))
        controller.commandPaletteIsShowing = false
        controller.performAction("new_float", on: tree)
        let float = try #require(controller.floats.last?.surface)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === float)
        controller.commandPaletteIsShowing = true
        try await Task.sleep(for: .milliseconds(50))
        controller.commandPaletteIsShowing = false
        controller.performAction("toggle_floats_visible", on: float)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.floatsHidden)
        #expect(window.firstResponder === tree)
    }

    @Test(arguments: [false, true])
    func shellExitRemovesFloatWithoutChangingScriptedCommandWaiting(reloadConfig: Bool) async throws {
        let controller = try makeController(live: true, command: "/bin/sh -c 'sleep 1; exit 0'")
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        let float = try #require(controller.newFloat())
        if reloadConfig {
            let config = try TemporaryConfig("wait-after-command = true")
            ghostty_surface_update_config(try #require(float.surface), try #require(config.config))
        }
        try #require(float.surfaceModel).sendText("sleep 1; exit\n")
        let deadline = Date().addingTimeInterval(5)
        while !float.processExited || !tree.processExited || !controller.floats.isEmpty, Date() < deadline {
            controller.ghostty.appTick()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(float.processExited)
        #expect(controller.floats.isEmpty)
        #expect(controller.focusedSurface === tree)
        #expect(tree.processExited)
        #expect(controller.surfaceTree.contains(tree))
    }

    @Test func navigationTraversesThreeFloatsInBothDirectionsAfterRaising() async throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        let third = try #require(controller.newFloat())
        let window = try #require(controller.window)
        try await waitForLayout { window.firstResponder === third }
        for expected in [second, first, third, second] {
            controller.performAction("focus_float:previous", on: try #require(controller.focusedSurface))
            try await waitForLayout { window.firstResponder === expected }
            #expect(controller.focusedSurface === expected)
            #expect(controller.floats.last?.surface === expected)
            #expect(window.firstResponder === expected)
        }
        for expected in [third, first, second, third] {
            controller.performAction("focus_float:next", on: try #require(controller.focusedSurface))
            try await waitForLayout { window.firstResponder === expected }
            #expect(controller.focusedSurface === expected)
            #expect(controller.floats.last?.surface === expected)
            #expect(window.firstResponder === expected)
        }
        controller.focusSurface(first)
        try await waitForLayout { window.firstResponder === first }
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_PREVIOUS)
        #expect(controller.focusedSurface === third)
        controller.closeSurface(third, withConfirmation: false)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_PREVIOUS)
        #expect(controller.focusedSurface === second)
    }

    @Test(arguments: [false, true])
    func splitUndoDoesNotRetainAClosedFloatOrResurrectItOnRedo(undoBeforeClosing: Bool) async throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        let sibling = Ghostty.SurfaceView(try #require(controller.ghostty.app), deferTerminal: true)
        controller.surfaceTree = try controller.surfaceTree.inserting(view: sibling, at: tree, direction: .right)
        controller.history.groupsByEvent = false
        weak var closedFloat: Ghostty.SurfaceView?
        do {
            let float = try #require(controller.newFloat())
            closedFloat = float
            controller.history.beginUndoGrouping()
            controller.closeSurface(sibling, withConfirmation: false)
            controller.history.endUndoGrouping()
            if undoBeforeClosing { controller.history.undo() }
            controller.closeSurface(float, withConfirmation: false)
        }
        let deadline = Date().addingTimeInterval(2)
        while closedFloat != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(closedFloat == nil)
        if !undoBeforeClosing {
            try #require(controller.history.canUndo)
            controller.history.undo()
        }
        #expect(controller.surfaceTree.contains(sibling))
        try #require(controller.history.canRedo)
        #expect(controller.floats.isEmpty)
        controller.history.redo()
        #expect(!controller.surfaceTree.contains(sibling))
        #expect(controller.floats.isEmpty)
    }

    @Test func refusesToFloatTheOnlyTreeSurface() throws {
        let controller = try makeController()
        defer { controller.window?.close() }
        let surface = controller.surfaceTree.first
        #expect(!controller.toggleFloatDock())
        #expect(controller.surfaceTree.first === surface)
        #expect(controller.floats.isEmpty)
    }

    @Test func visibilityAndCloseRestoreFocusAndNewFloatUnhides() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        controller.toggleFloatsVisible()
        #expect(controller.floatsHidden)
        #expect(controller.focusedSurface === tree)
        let third = try #require(controller.newFloat())
        #expect(!controller.floatsHidden)
        #expect(controller.floats.count == 3)
        #expect(controller.focusedSurface === third)
        controller.closeSurface(third, withConfirmation: false)
        #expect(controller.focusedSurface === second)
        controller.closeSurface(second, withConfirmation: false)
        #expect(controller.focusedSurface === first)
        controller.closeSurface(first, withConfirmation: false)
        #expect(controller.focusedSurface === tree)
        #expect(controller.surfaceTree.first === tree)
    }

    @Test func cyclesFloatsAndNeverChangesTheTreeTitle() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        tree.titleOverride = "Tree title"
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        first.titleOverride = "Float title"
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_NEXT)
        #expect(controller.focusedSurface === first)
        #expect(controller.floats.last?.surface === first)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_PREVIOUS)
        #expect(controller.focusedSurface === second)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_TREE)
        #expect(controller.focusedSurface === tree)
        controller.toggleFloatsVisible()
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_NEXT)
        #expect(!controller.floatsHidden)
        #expect(controller.focusedSurface === second)
        #expect(controller.window?.title == "Tree title")
        controller.toggleFloatsVisible()
        controller.focusSurface(first)
        #expect(!controller.floatsHidden)
        #expect(controller.floats.last?.surface === first)
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface,
                                        object: second, userInfo: ["process_alive": false])
        #expect(!controller.floats.contains(where: { $0.surface === second }))
        #expect(controller.focusedSurface === first)
    }

    @Test func busyFloatRequiresConfirmationEvenWhenTreeIsIdleOrSaved() async throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first?.surface)
        let idleConfig = try TemporaryConfig("confirm-close-surface = false")
        ghostty_surface_update_config(tree, try #require(idleConfig.config))
        let float = try #require(controller.newFloat())
        let busyConfig = try TemporaryConfig("confirm-close-surface = always")
        ghostty_surface_update_config(try #require(float.surface), try #require(busyConfig.config))
        #expect(float.needsConfirmQuit)
        #expect(!controller.surfaceTree.contains(where: { $0.needsConfirmQuit }))
        #expect(!controller.windowCanBeClosedWithoutConfirmation())
        let floatPrompt = await withCheckedContinuation { continuation in
            controller.onConfirmation = { continuation.resume(returning: $0) }
            controller.closeSurface(float)
        }
        #expect(floatPrompt == "Close Terminal?")
        #expect(controller.floats.count == 1)
        let tabPrompt = await withCheckedContinuation { continuation in
            controller.onConfirmation = { continuation.resume(returning: $0) }
            controller.closeTab(nil)
        }
        #expect(tabPrompt == "Close Window?" || tabPrompt == "Close Tab?")
        controller.sidebarItem.lifecycle.pin(true)
        #expect(controller.needsQuitConfirmation)
    }

    @Test func persistenceAndTabUndoExcludeFloatsAndSaveTreeFocus() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        let float = try #require(controller.newFloat())
        let state = TerminalRestorableState(from: controller)
        #expect(state.focusedSurface == tree.id.uuidString)
        #expect(state.surfaceTree.count == 1)
        #expect(!state.surfaceTree.contains(float))
        let data = try JSONEncoder().encode(state)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains(float.id.uuidString))
        #expect(controller.undoState?.focusedSurface == tree.id)
        #expect(controller.undoState?.surfaceTree.contains(float) == false)
    }

    @Test func minimizeRestoreAndCollapsePillState() async throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let tree = try #require(controller.surfaceTree.first)
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        let window = try #require(controller.window)
        try await waitForLayout { window.firstResponder === second }
        #expect(window.firstResponder === second)

        // Minimizing the focused float focuses the next shown float.
        controller.minimizeFloat(second)
        try await waitForLayout { window.firstResponder === first }
        #expect(window.firstResponder === first)
        #expect(controller.collapsedFloats.map(\.surface) == [second])
        #expect(controller.shownFloats.map(\.surface) == [first])
        #expect(controller.focusedSurface === first)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_NEXT)
        #expect(controller.focusedSurface === first)

        // Last shown float minimized: focus falls back to the tree.
        controller.minimizeFloat(first)
        try await waitForLayout { window.firstResponder === tree }
        #expect(window.firstResponder === tree)
        #expect(controller.shownFloats.isEmpty)
        #expect(controller.focusedSurface === tree)

        // Restoring one float leaves the other in the pill.
        controller.restoreFloat(second)
        try await waitForLayout { window.firstResponder === second }
        #expect(window.firstResponder === second)
        // Focus must survive the restore animation and fade-in finishing.
        try await Task.sleep(for: .milliseconds(450))
        #expect(window.firstResponder === second)
        #expect(controller.floats.first(where: { $0.surface === second })?.snapshot == nil)
        #expect(controller.shownFloats.map(\.surface) == [second])
        #expect(controller.collapsedFloats.map(\.surface) == [first])
        #expect(controller.focusedSurface === second)

        // Toggle restores everything while anything is collapsed, then collapses all.
        controller.toggleFloatsVisible()
        #expect(controller.collapsedFloats.isEmpty)
        #expect(controller.shownFloats.count == 2)
        controller.toggleFloatsVisible()
        #expect(controller.floatsHidden)
        #expect(controller.collapsedFloats.count == 2)
        #expect(controller.focusedSurface === tree)

        // Restoring one float out of collapse-all keeps the rest collapsed.
        controller.restoreFloat(first)
        #expect(!controller.floatsHidden)
        #expect(controller.shownFloats.map(\.surface) == [first])
        #expect(controller.collapsedFloats.map(\.surface) == [second])

        // Focusing a minimized float (e.g. via present_terminal) reveals it.
        controller.focusSurface(second)
        #expect(controller.collapsedFloats.isEmpty)
    }

    @Test func maximizeTogglesAndManualMoveForgetsRestoreFrame() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        controller.layoutFloats(in: CGSize(width: 1000, height: 600))
        let float = try #require(controller.newFloat())
        let original = try #require(controller.floats.last?.frame)
        controller.toggleFloatMaximized(float)
        #expect(controller.floats.last?.frame == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(controller.floats.last?.isMaximized == true)
        controller.toggleFloatMaximized(float)
        #expect(controller.floats.last?.frame == original)
        #expect(controller.floats.last?.isMaximized == false)
        controller.toggleFloatMaximized(float)
        controller.moveFloat(float, to: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(controller.floats.last?.isMaximized == false)
    }

    @Test func restoringFloatsWithoutAFocusChangeIncludesThemInTraversal() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        controller.minimizeFloat(first)
        controller.focusSurface(second)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_NEXT)
        #expect(controller.focusedSurface === second)
        // Second stays topmost and focused, so restoring doesn't change focus.
        controller.restoreAllFloats()
        #expect(controller.focusedSurface === second)
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_NEXT)
        #expect(controller.focusedSurface === first)
    }

    @Test func newFloatAfterCollapseAllShowsEveryFloat() throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        controller.minimizeFloat(second)
        controller.collapseAllFloats()
        let third = try #require(controller.newFloat())
        #expect(!controller.floatsHidden)
        #expect(controller.collapsedFloats.isEmpty)
        #expect(Set(controller.shownFloats.map(\.id)) == Set([first.id, second.id, third.id]))
    }

    @Test func staleSwiftUIFocusReportForAnotherFloatIsIgnored() async throws {
        let controller = try makeController(live: true)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let first = try #require(controller.newFloat())
        let second = try #require(controller.newFloat())
        let third = try #require(controller.newFloat())
        controller.focusSurface(second)
        try await waitForLayout { window.firstResponder === second }
        #expect(window.firstResponder === second)

        // A late SwiftUI report naming another visible float must not refocus or raise it.
        controller.focusedSurfaceReported(first)
        #expect(controller.focusedSurface === second)
        #expect(controller.floats.last?.surface === second)

        // Navigation starts from the float that really has focus (z-order: first, third, second).
        controller.focusFloat(GHOSTTY_FOCUS_FLOAT_PREVIOUS)
        #expect(controller.focusedSurface === third)

        // A report that matches the actual first responder is still accepted.
        try await waitForLayout { window.firstResponder === third }
        controller.focusedSurfaceReported(third)
        #expect(controller.focusedSurface === third)
    }
}

