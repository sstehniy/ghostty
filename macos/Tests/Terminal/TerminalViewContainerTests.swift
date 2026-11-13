//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @MainActor @Test func sidebarTransitionsPreserveLayout() async throws {
        let appDelegate = try #require(NSApp.delegate as? AppDelegate)
        let controller = TerminalController(appDelegate.ghostty, withSurfaceTree: .init())
        let model = TerminalTabSidebarModel(configuredLayout: .horizontal)
        let sidebar = TerminalTabSidebarHostView(model: model, actions: controller)
        sidebar.preferredWidth = 280
        let container = TerminalViewContainer { EmptyView() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = container
        container.installSidebar(sidebar)
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded()
        let edge = container.sheetEdgeFrameView
        let terminal = try #require(container.subviews.first { $0 !== sidebar })
        container.updateSheetEdge(chrome: .black, stroke: .white, mode: .full, contentInset: 4)
        #expect(container.sheetCornerRadius == TerminalViewContainer.preferredSheetCornerRadius)

        // The edge rides on the terminal, above its content and below the sidebar.
        #expect(edge.superview === terminal)
        #expect(terminal.subviews.last === edge)
        #expect(try #require(container.subviews.firstIndex(of: terminal))
            < (try #require(container.subviews.firstIndex(of: sidebar))))
        func edgeFrame() -> NSRect { container.convert(edge.frame, from: terminal) }

        container.setSidebarVisible(true)
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 280)
        #expect(edgeFrame() == terminal.frame)
        #expect(!edge.isHidden)

        // Rapid toggles must settle on the last requested layout.
        container.setSidebarVisible(false, animated: true)
        try await Task.sleep(for: .milliseconds(50))
        let sidebarFrame = try #require(sidebar.layer?.presentation()).frame
        let terminalFrame = try #require(terminal.layer?.presentation()).frame
        #expect(abs(sidebarFrame.maxX - terminalFrame.minX) < 1)
        container.setSidebarVisible(true, animated: true)
        try await Task.sleep(for: .milliseconds(50))
        container.setSidebarVisible(false, animated: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(sidebar.isHidden)
        #expect(edge.isHidden)
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 0)
        #expect(edgeFrame() == terminal.frame)

        container.setSidebarVisible(true, animated: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!sidebar.isHidden)
        #expect(!edge.isHidden)
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 280)
        #expect(edgeFrame() == terminal.frame)

        // The edge never takes clicks.
        #expect(edge.hitTest(NSPoint(x: edge.frame.minX + 2, y: edge.frame.maxY - 2)) == nil)
    }

    @Test func sheetCornerNeverReachesTheGrid() {
        // Enough padding keeps the full corner.
        #expect(TerminalViewContainer.sheetCornerRadius(contentInset: 4) == 10)
        // Default padding shrinks it; no padding squares it.
        #expect(TerminalViewContainer.sheetCornerRadius(contentInset: 2) < 10)
        #expect(TerminalViewContainer.sheetCornerRadius(contentInset: 0) == 0)

        // The fill is the square corner minus a quarter disc of radius r. A cell's
        // top-left at (inset, inset) must lie inside that disc for every inset.
        for step in 0...40 {
            let inset = CGFloat(step) / 4
            let radius = TerminalViewContainer.sheetCornerRadius(contentInset: inset)
            guard radius > 0, inset < radius else { continue }
            let distance = hypot(radius - inset, radius - inset)
            #expect(distance <= radius + 0.0001, "inset \(inset) radius \(radius)")
        }
    }

    /// A config reload doesn't move an existing surface's grid, so the corner must
    /// follow the padding the surface applies, not the reloaded config.
    @MainActor @Test func sheetCornerFollowsAppliedPaddingAcrossReload() throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let current = try #require(ghostty.config.config)
        let original = try #require(ghostty_config_clone(current))
        defer {
            ghostty_app_update_config(app, original)
            ghostty_config_free(original)
        }

        func padding(_ points: Int) -> String {
            "window-padding-x = \(points)\nwindow-padding-y = \(points)\nwindow-padding-balance = false\n"
        }
        let config = try TemporaryConfig(padding(0))
        ghostty_app_update_config(app, try #require(config.config))

        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sleep 60"
        func makeController() throws -> (TerminalController, Ghostty.SurfaceView) {
            let surface = Ghostty.SurfaceView(app, baseConfig: base)
            let controller = TerminalController(ghostty, withSurfaceTree: .init(view: surface))
            let window = try #require(controller.window)
            window.isReleasedWhenClosed = false
            window.setContentSize(CGSize(width: 900, height: 500))
            window.contentView?.layoutSubtreeIfNeeded()
            return (controller, surface)
        }

        let (controller, surface) = try makeController()
        defer { controller.window?.close() }
        #expect(surface.gridTopLeftInset == .zero)
        #expect(controller.sheetCornerInset() == 0)

        // Reload with room for the full corner. The open terminal keeps its padding,
        // so the corner must stay square rather than grow over the first cell.
        try config.reload(padding(4))
        ghostty_app_update_config(app, try #require(config.config))
        ghostty_surface_update_config(try #require(surface.surface), try #require(config.config))
        #expect(surface.gridTopLeftInset == .zero)
        #expect(controller.sheetCornerInset() == 0)
        #expect(TerminalViewContainer.sheetCornerRadius(contentInset: controller.sheetCornerInset()) == 0)

        // A terminal opened after the reload has the new padding and the full corner.
        let (fresh, _) = try makeController()
        defer { fresh.window?.close() }
        #expect(fresh.sheetCornerInset() == 4)
        #expect(TerminalViewContainer.sheetCornerRadius(contentInset: fresh.sheetCornerInset()) == 10)
    }

    /// Font changes rebalance padding without resizing the surface, so the applied
    /// corner must follow cell size changes too.
    @MainActor @Test func sheetCornerFollowsPaddingRebalancedByFontChanges() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let current = try #require(ghostty.config.config)
        let original = try #require(ghostty_config_clone(current))
        defer {
            ghostty_app_update_config(app, original)
            ghostty_config_free(original)
        }
        let config = try TemporaryConfig("""
            font-size = 12
            window-padding-x = 0
            window-padding-y = 0
            window-padding-balance = equal
            """)
        ghostty_app_update_config(app, try #require(config.config))

        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(app, baseConfig: base)
        let controller = TerminalController(ghostty, withSurfaceTree: .init(view: surface))
        let window = try #require(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(CGSize(width: 900, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.focusedSurfaceDidChange(to: surface)
        let container = try #require(controller.terminalViewContainer)
        let handle = try #require(surface.surface)

        // The radius the corner should have for the padding the surface applies now.
        func expectedRadius() throws -> CGFloat {
            let inset = try #require(surface.gridTopLeftInset)
            return TerminalViewContainer.sheetCornerRadius(contentInset: min(inset.width, inset.height))
        }
        func settles() async throws -> Bool {
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if container.sheetCornerRadius == (try expectedRadius()) { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return container.sheetCornerRadius == (try expectedRadius())
        }

        #expect(try await settles())
        var previous = try expectedRadius()
        var paddingMoved = false
        for size in 13...24 {
            let action = "set_font_size:\(size)"
            try #require(ghostty_surface_binding_action(handle, action, UInt(action.utf8.count)))
            let settled = try await settles()
            let radius = try expectedRadius()
            #expect(settled, "font size \(size): corner \(container.sheetCornerRadius), padding allows \(radius)")
            if radius != previous { paddingMoved = true }
            previous = radius
        }
        // Only meaningful if some font size actually moved the balanced padding.
        #expect(paddingMoved)
    }

    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }
}
