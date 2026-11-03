//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

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
        let terminal = try #require(container.subviews.first { $0 !== sidebar })

        container.setSidebarVisible(true)
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 280)

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
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 0)

        container.setSidebarVisible(true, animated: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!sidebar.isHidden)
        #expect(sidebar.frame.width == 280)
        #expect(terminal.frame.minX == 280)
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
