import AppKit
import GhosttyKit
import SwiftUI

struct FloatPane: Identifiable {
    let surface: Ghostty.SurfaceView
    var frame: CGRect
    /// Collapsed into the top-right float pill independently of the other floats.
    var minimized = false
    /// The frame to go back to when un-maximizing; non-nil while maximized.
    var restoreFrame: CGRect?
    /// What the terminal looked like when it was last collapsed, drawn by the
    /// collapse/restore animation in place of the live (unanimatable) surface.
    var snapshot: NSImage?
    /// Set while a maximize or restore plays. The live card stays hidden meanwhile.
    var resize: Resize?

    struct Resize {
        let id = UUID()
        let from: CGRect
        let snapshot: NSImage?
    }

    var id: UUID { surface.id }
    var isMaximized: Bool { restoreFrame != nil }

    /// Used for showing and collapsing floats. Never animate a change that also
    /// reorders `floats` (raising): SwiftUI then re-inserts the surface view and it
    /// loses first responder. Never animate `frame` either: the live terminal would
    /// resize, and the shell redraw, on every frame.
    static let animation = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// How long a ghost takes to stand in for a float's live terminal.
    static let ghostDuration: Double = 0.26

    static func normalized(_ frame: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: frame.minX / size.width, y: frame.minY / size.height,
                      width: frame.width / size.width, height: frame.height / size.height)
    }

    static func points(_ frame: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: frame.minX * size.width, y: frame.minY * size.height,
               width: frame.width * size.width, height: frame.height * size.height)
    }

    static func clamped(_ frame: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let width = min(1, max(min(240 / size.width, 1), frame.width))
        let height = min(1, max(min(120 / size.height, 1), frame.height))
        return CGRect(x: min(max(0, frame.minX), 1 - width),
                      y: min(max(0, frame.minY), 1 - height), width: width, height: height)
    }

    /// Distance of a new float from the container's top and right edges, in points.
    static let initialMargin: CGFloat = 24

    /// The first float sits near the top-right corner. Each extra float cascades
    /// 24 pt down and to the left, wrapping back to the corner when it would overflow.
    static func initialFrame(width: Double, height: Double, in size: CGSize, after previous: CGRect?) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return CGRect(x: 1 - width, y: 0, width: width, height: height)
        }
        let sized = clamped(CGRect(x: 0, y: 0, width: width, height: height), in: size)
        let marginX = initialMargin / size.width, marginY = initialMargin / size.height
        let corner = clamped(CGRect(x: 1 - sized.width - marginX, y: marginY,
                                    width: sized.width, height: sized.height), in: size)
        guard let previous else { return corner }
        let cascaded = CGRect(x: previous.minX - marginX, y: previous.minY + marginY,
                              width: corner.width, height: corner.height)
        guard cascaded.minX >= 0, cascaded.maxY <= 1 else { return corner }
        return cascaded
    }
}

extension BaseTerminalController {
    @IBAction func performFloatingPaneAction(_ sender: NSMenuItem) {
        guard self is TerminalController, let action = sender.representedObject as? String,
              let surface = focusedSurface?.surface else { return }
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @discardableResult
    func newFloat(inheritSSH: Bool = true) -> Ghostty.SurfaceView? {
        guard self is TerminalController,
              let app = ghostty.app,
              let parent = treeFocusSurface?.surface else { return nil }
        var config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(
            parent, GHOSTTY_SURFACE_CONTEXT_SPLIT))
        // Floats always start the login shell, even when the tab runs a custom command.
        if let shell = getpwuid(getuid())?.pointee.pw_shell {
            config.command = String(cString: shell)
        } else {
            config.command = "/bin/sh"
        }
        config.initialInput = nil
        config.closeOnExit = true
        if inheritSSH && ghostty.config.sshInheritSession, let source = treeFocusSurface {
            TerminalSSHReconnect.inherit(from: source, to: &config, waitAfterCommand: ghostty.config.waitAfterCommand)
        }
        let surface = Ghostty.SurfaceView(app, baseConfig: config)
        appendFloat(surface)
        focusSurface(surface)
        return surface
    }

    private func appendFloat(_ surface: Ghostty.SurfaceView) {
        // Leaving a collapse-all shows every float, like toggle_floats_visible.
        if floatsHidden {
            for index in floats.indices where floats[index].minimized { floats[index].minimized = false }
            floatsHidden = false
        }
        floats.append(FloatPane(surface: surface, frame: FloatPane.initialFrame(
            width: ghostty.config.floatWidth, height: ghostty.config.floatHeight,
            in: floatContainerSize, after: floats.last?.frame)))
    }

    func layoutFloats(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        floatContainerSize = size
        for index in floats.indices {
            let frame = FloatPane.clamped(floats[index].frame, in: size)
            if floats[index].frame != frame { floats[index].frame = frame }
        }
    }

    func moveFloat(_ surface: Ghostty.SurfaceView, to frame: CGRect) {
        guard let index = floats.firstIndex(where: { $0.surface === surface }) else { return }
        floats[index].frame = FloatPane.clamped(frame, in: floatContainerSize)
        floats[index].restoreFrame = nil
    }

    /// Floats that are currently on screen, in z-order.
    var shownFloats: [FloatPane] {
        floatsHidden ? [] : floats.filter { !$0.minimized }
    }

    /// Floats that are currently collapsed, in z-order.
    var collapsedFloats: [FloatPane] {
        floatsHidden ? floats : floats.filter(\.minimized)
    }

    /// A float's place in the overlay's stacking order, or -1 once it is gone, so a
    /// ghost outliving its float stays below every card.
    func floatStackPosition(_ id: UUID) -> Double {
        Double(floats.firstIndex { $0.id == id } ?? -1)
    }

    func isFloatShown(_ surface: Ghostty.SurfaceView) -> Bool {
        shownFloats.contains(where: { $0.surface === surface })
    }

    /// Make a float visible without changing focus. Restoring one float out of a
    /// collapse-all keeps the others collapsed.
    func revealFloat(_ surface: Ghostty.SurfaceView) {
        guard let index = floats.firstIndex(where: { $0.surface === surface }) else { return }
        if floatsHidden {
            for other in floats.indices { floats[other].minimized = true }
            floatsHidden = false
        }
        if floats[index].minimized { floats[index].minimized = false }
    }

    func restoreFloat(_ surface: Ghostty.SurfaceView) {
        // Raise while still collapsed so the animated reveal doesn't reorder visible floats.
        raiseFloat(surface)
        withAnimation(FloatPane.animation) { revealFloat(surface) }
        focusSurface(surface)
    }

    private func raiseFloat(_ surface: Ghostty.SurfaceView) {
        guard let index = floats.firstIndex(where: { $0.surface === surface }),
              index != floats.count - 1 else { return }
        floats.append(floats.remove(at: index))
    }

    func minimizeFloat(_ surface: Ghostty.SurfaceView) {
        guard let index = floats.firstIndex(where: { $0.surface === surface }) else { return }
        let wasFocused = focusedSurface === surface
        if isFloatShown(surface) { floats[index].snapshot = surface.asImage }
        withAnimation(FloatPane.animation) { floats[index].minimized = true }
        paneFocusOrder = nil
        if wasFocused, let target = shownFloats.last?.surface ?? treeFocusSurface { focusSurface(target) }
    }

    func restoreAllFloats() {
        guard !floats.isEmpty else { return }
        withAnimation(FloatPane.animation) {
            floatsHidden = false
            for index in floats.indices where floats[index].minimized { floats[index].minimized = false }
        }
        if let target = floats.last?.surface { focusSurface(target) }
    }

    func collapseAllFloats() {
        guard !floats.isEmpty else { return }
        for index in floats.indices where isFloatShown(floats[index].surface) {
            floats[index].snapshot = floats[index].surface.asImage
        }
        withAnimation(FloatPane.animation) { floatsHidden = true }
        if let target = treeFocusSurface { focusSurface(target) }
    }

    /// Drop a float's collapse snapshot once its restore animation has taken it.
    func clearFloatSnapshot(_ id: UUID) {
        guard let index = floats.firstIndex(where: { $0.id == id }), floats[index].snapshot != nil else { return }
        floats[index].snapshot = nil
    }

    /// The frame changes once, without animation, so the terminal resizes a single
    /// time. A ghost plays the transition while the live card stays hidden.
    func toggleFloatMaximized(_ surface: Ghostty.SurfaceView) {
        focusSurface(surface)
        guard let index = floats.firstIndex(where: { $0.surface === surface }) else { return }
        let resize = FloatPane.Resize(from: floats[index].frame, snapshot: surface.asImage)
        if let restore = floats[index].restoreFrame {
            floats[index].frame = FloatPane.clamped(restore, in: floatContainerSize)
            floats[index].restoreFrame = nil
        } else {
            floats[index].restoreFrame = floats[index].frame
            floats[index].frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        floats[index].resize = resize
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatPane.ghostDuration * 0.85) { [weak self] in
            self?.finishFloatResize(surface, id: resize.id)
        }
    }

    private func finishFloatResize(_ surface: Ghostty.SurfaceView, id: UUID) {
        guard let index = floats.firstIndex(where: { $0.surface === surface }),
              floats[index].resize?.id == id else { return }
        withAnimation(.easeOut(duration: 0.1)) { floats[index].resize = nil }
    }

    func focusFloat(_ direction: ghostty_action_focus_float_e) {
        guard self is TerminalController else { return }
        if direction == GHOSTTY_FOCUS_FLOAT_TREE {
            if let surface = treeFocusSurface { focusSurface(surface) }
            return
        }
        guard !floats.isEmpty else { return }
        if shownFloats.isEmpty {
            withAnimation(FloatPane.animation) {
                floatsHidden = false
                for index in floats.indices where floats[index].minimized { floats[index].minimized = false }
            }
        }
        // Raising the target changes z-order, but must not change an ongoing traversal.
        let shown = shownFloats
        // A cached order is only valid for the same set of shown floats: restoring
        // floats without a focus change would otherwise leave them out of the cycle.
        let shownIDs = shown.map(\.id)
        let order = paneFocusOrder.flatMap { Set($0) == Set(shownIDs) ? $0 : nil } ?? shownIDs
        guard let topmost = shown.last?.id else { return }
        var targetID = topmost
        // focusedSurface can be stale: SwiftUI may report an older surface after a
        // float already became first responder. Fall back to the actual responder.
        let responder = window?.firstResponder as? Ghostty.SurfaceView
        let currentSurface = [focusedSurface, responder].compactMap { $0 }.first { order.contains($0.id) }
        if let currentSurface, let current = order.firstIndex(of: currentSurface.id) {
            let offset = direction == GHOSTTY_FOCUS_FLOAT_PREVIOUS ? -1 : 1
            targetID = order[(current + offset + order.count) % order.count]
        }
        guard let target = floats.first(where: { $0.id == targetID })?.surface else { return }
        focusSurface(target)
        paneFocusOrder = order
    }

    func toggleFloatsVisible() {
        guard self is TerminalController, !floats.isEmpty else { return }
        if collapsedFloats.isEmpty { collapseAllFloats() } else { restoreAllFloats() }
    }

    @discardableResult
    func toggleFloatDock(_ target: Ghostty.SurfaceView? = nil) -> Bool {
        guard self is TerminalController, let surface = target ?? focusedSurface else { return false }
        if let index = floats.firstIndex(where: { $0.surface === surface }) {
            guard let target = treeFocusSurface else { return false }
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection =
                target.bounds.width > target.bounds.height ? .right : .down
            do {
                let tree = try surfaceTree.inserting(view: surface, at: target, direction: direction)
                surfaceTree = tree
                floats.remove(at: index)
            } catch {
                Ghostty.logger.warning("failed to dock floating pane: \(error, privacy: .public)")
                return false
            }
        } else {
            guard let node = surfaceTree.root?.node(view: surface) else {
                NSSound.beep()
                return false
            }
            // An empty tree closes the tab, so a fresh shell takes the only pane's place.
            let tree: SplitTree<Ghostty.SurfaceView>
            if surfaceTree.isSplit {
                tree = surfaceTree.removing(node)
            } else {
                guard let replacement = makeTreeReplacement(for: surface) else {
                    NSSound.beep()
                    return false
                }
                tree = SplitTree(view: replacement)
            }
            appendFloat(surface)
            surfaceTree = tree
            lastFocusedTreeSurface = surfaceTree.first
        }
        // Old tree snapshots could otherwise reinsert a surface that is now floating.
        undoManager?.removeAllActions(withTarget: self)
        focusSurface(surface)
        return true
    }

    /// A new shell configured like a split of `surface`.
    private func makeTreeReplacement(for surface: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        guard let app = ghostty.app, let parent = surface.surface else { return nil }
        var config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(
            parent, GHOSTTY_SURFACE_CONTEXT_SPLIT))
        if ghostty.config.sshInheritSession {
            TerminalSSHReconnect.inherit(from: surface, to: &config, waitAfterCommand: ghostty.config.waitAfterCommand)
        }
        return Ghostty.SurfaceView(app, baseConfig: config)
    }

    func removeFloat(_ surface: Ghostty.SurfaceView) {
        guard floats.contains(where: { $0.surface === surface }) else { return }
        let wasFocused = focusedSurface === surface
        floats.removeAll { $0.surface === surface }
        if wasFocused {
            if let target = shownFloats.last?.surface ?? treeFocusSurface { focusSurface(target) }
        }
    }
}
