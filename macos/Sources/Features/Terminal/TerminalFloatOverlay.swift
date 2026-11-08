import AppKit
import SwiftUI

struct TerminalFloatOverlay: View {
    @ObservedObject var controller: BaseTerminalController

    /// Ids shown on screen at the last update, used to tell which floats were just
    /// collapsed or restored.
    @State private var lastShown: [UUID] = []
    @State private var lastCollapsed: Set<UUID> = []
    /// Restored floats kept hidden until their ghost lands, keyed by float id. The
    /// value identifies the restore, so a timer from an earlier restore of the same
    /// float can't end a newer one early.
    @State private var fadingIn: [UUID: UUID] = [:]
    @State private var ghosts: [FloatGhost.Model] = []
    @State private var pillFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Directly below the ghost's own card: over the floats its pane is above,
                // and under its card so that fades in on top of the landed ghost.
                ForEach(ghosts) { ghost in
                    FloatGhost(model: ghost)
                        .zIndex(controller.floatStackPosition(ghost.paneID) - 0.5)
                }

                ForEach(controller.shownFloats) { pane in
                    let frame = FloatPane.points(FloatPane.clamped(pane.frame, in: geometry.size), in: geometry.size)
                    let headerFrame = CGRect(origin: frame.origin,
                                             size: CGSize(width: frame.width, height: TerminalFloatCard.headerHeight))
                    let headerTrailingInset = headerFrame.intersects(pillFrame) ? frame.maxX - pillFrame.minX + 8 : 4
                    TerminalFloatCard(controller: controller, surface: pane.surface, frame: frame,
                                      containerSize: geometry.size, isMaximized: pane.isMaximized,
                                      headerTrailingInset: headerTrailingInset)
                        .frame(width: frame.width, height: frame.height)
                        // The live terminal is never scaled: resizing it every frame makes it
                        // flicker. A ghost card flies to or from the pill instead, and a restored
                        // card fades in once its ghost lands. Near zero rather than zero, since
                        // SwiftUI hides fully transparent views and they can't take focus.
                        .opacity(isAwaitingGhost(pane) ? 0.001 : 1)
                        .offset(x: frame.minX, y: frame.minY)
                        // Never give insertion an animated transition: SwiftUI re-hosts the
                        // terminal view when it ends, which drops first responder.
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                        .zIndex(controller.floatStackPosition(pane.id))
                }

                if !controller.floats.isEmpty {
                    TerminalFloatPill(controller: controller)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("floatingPanes"))
                        } action: { pillFrame = $0 }
                        .padding(8)
                        .frame(width: geometry.size.width, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topTrailing)))
                        .zIndex(Double(controller.floats.count))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: "floatingPanes")
            .onAppear {
                controller.layoutFloats(in: geometry.size)
                lastShown = controller.shownFloats.map(\.id)
                lastCollapsed = Set(controller.collapsedFloats.map(\.id))
            }
            .onChange(of: geometry.size) { controller.layoutFloats(in: $0) }
            .onChange(of: controller.shownFloats.map(\.id)) { shown in
                animateCollapseChanges(to: shown, in: geometry.size)
            }
            .onChange(of: controller.floats.compactMap(\.resize?.id)) { _ in
                launchResizeGhosts(in: geometry.size)
            }
        }
    }

    /// Launch ghosts between the pill and each float that was just collapsed or restored.
    /// Closed and newly created floats just fade.
    private func animateCollapseChanges(to shown: [UUID], in size: CGSize) {
        let pill = pillFrame
        let shownSet = Set(shown), lastSet = Set(lastShown)
        for pane in controller.floats {
            let frame = FloatPane.points(FloatPane.clamped(pane.frame, in: size), in: size)
            if lastSet.contains(pane.id) && !shownSet.contains(pane.id) {
                fadingIn[pane.id] = nil
                launchGhost(FloatGhost.Model(from: frame, to: pill, collapsing: true, pane: pane))
            } else if !lastSet.contains(pane.id) && shownSet.contains(pane.id) && lastCollapsed.contains(pane.id) {
                let ghost = FloatGhost.Model(from: pill, to: frame, collapsing: false, pane: pane)
                launchGhost(ghost)
                fadingIn[pane.id] = ghost.id
                // The ghost holds its own copy; don't keep a full-size image per float.
                controller.clearFloatSnapshot(pane.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + FloatPane.ghostDuration * 0.85) {
                    guard fadingIn[pane.id] == ghost.id else { return }
                    withAnimation(.easeOut(duration: 0.1)) { fadingIn[pane.id] = nil }
                }
            }
        }
        lastShown = shown
        lastCollapsed = Set(controller.collapsedFloats.map(\.id))
    }

    private func launchResizeGhosts(in size: CGSize) {
        for pane in controller.floats {
            guard let resize = pane.resize, !ghosts.contains(where: { $0.id == resize.id }) else { continue }
            launchGhost(FloatGhost.Model(resize: resize, pane: pane, in: size))
        }
    }

    /// True for a float that is being resized or restored, until its ghost lands.
    /// Derived from the previous state too, so the card never flashes for one frame
    /// before `animateCollapseChanges` runs.
    private func isAwaitingGhost(_ pane: FloatPane) -> Bool {
        pane.resize != nil || fadingIn[pane.id] != nil ||
            (!lastShown.contains(pane.id) && lastCollapsed.contains(pane.id))
    }

    /// At most one ghost per float: a new collapse/restore replaces one still flying.
    private func launchGhost(_ ghost: FloatGhost.Model) {
        ghosts.removeAll { $0.paneID == ghost.paneID }
        ghosts.append(ghost)
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatPane.ghostDuration + 0.15) {
            ghosts.removeAll { $0.id == ghost.id }
        }
    }
}

// MARK: - Collapse ghost

/// A lightweight stand-in that flies between a float's frame and the collapsed pill,
/// or between its normal and maximized frames, so the live terminal is never animated.
private struct FloatGhost: View {
    enum Kind { case collapse, restore, resize }

    struct Model: Identifiable {
        let id: UUID
        let from: CGRect
        let to: CGRect
        let kind: Kind
        let paneID: UUID
        let title: String
        let snapshot: NSImage?
        var fromCornerRadius: CGFloat = 9
        var toCornerRadius: CGFloat = 9

        init(from: CGRect, to: CGRect, collapsing: Bool, pane: FloatPane) {
            self.id = UUID()
            self.from = from
            self.to = to
            self.kind = collapsing ? .collapse : .restore
            self.paneID = pane.id
            self.title = pane.surface.title
            self.snapshot = pane.snapshot
        }

        init(resize: FloatPane.Resize, pane: FloatPane, in size: CGSize) {
            self.id = resize.id
            self.from = FloatPane.points(FloatPane.clamped(resize.from, in: size), in: size)
            self.to = FloatPane.points(FloatPane.clamped(pane.frame, in: size), in: size)
            self.kind = .resize
            self.paneID = pane.id
            self.title = pane.surface.title
            self.snapshot = resize.snapshot
            self.fromCornerRadius = pane.isMaximized ? 9 : 0
            self.toCornerRadius = pane.isMaximized ? 0 : 9
        }
    }

    let model: Model
    @EnvironmentObject private var ghostty: Ghostty.App
    @State private var landed = false

    var body: some View {
        // Toward the pill, the ghost keeps the float's own size and is scaled down, so
        // the snapshot and header shrink together instead of being squashed. A resize
        // animates the ghost's real frame, like a window resizing around its contents.
        let target = landed ? model.to : model.from
        let full = model.kind == .resize ? target : (model.kind == .collapse ? model.from : model.to)
        let scale = model.kind == .resize ? 1 : max(0.05, min(target.width / full.width, target.height / full.height))
        let atPill = model.kind != .resize && landed == (model.kind == .collapse)
        let shape = RoundedRectangle(cornerRadius: landed ? model.toCornerRadius : model.fromCornerRadius,
                                     style: .continuous)

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(model.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.regularMaterial)

            ZStack(alignment: .topLeading) {
                ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity)
                if let snapshot = model.snapshot, model.kind == .resize {
                    // Zero minimums let a snapshot larger than the ghost be clipped
                    // instead of pushing the layout out to its own size.
                    Image(nsImage: snapshot)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                } else if let snapshot = model.snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .clipped()
        }
        .frame(width: full.width, height: full.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .scaleEffect(scale, anchor: .center)
        .offset(x: target.midX - full.width / 2, y: target.midY - full.height / 2)
        // Fade out as it reaches the pill, and in as it leaves it.
        .opacity(atPill ? 0 : 1)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: FloatPane.ghostDuration)) { landed = true }
        }
    }
}

// MARK: - Card

private struct TerminalFloatCard: View {
    static let headerHeight: CGFloat = 24

    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var surface: Ghostty.SurfaceView
    let frame: CGRect
    let containerSize: CGSize
    let isMaximized: Bool
    let headerTrailingInset: CGFloat

    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.displayScale) private var displayScale
    @State private var dragStart: CGRect?

    private var isFocused: Bool { controller.focusedSurface === surface }
    private var cornerRadius: CGFloat { isMaximized ? 0 : 9 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            Ghostty.InspectableSurface(surfaceView: surface, isSplit: false)
                .overlay {
                    // Floats have their own dim strength (unfocused-float-opacity). The layer
                    // always exists and only its opacity changes, so focus changes don't
                    // restructure the view hosting the terminal.
                    Rectangle()
                        .fill(ghostty.config.unfocusedSplitFill)
                        .opacity(isFocused ? 0 : ghostty.config.unfocusedFloatOpacity)
                        .allowsHitTesting(false)
                }
        }
        // The terminal paints its own (possibly translucent) background. Only back it
        // when opaque, to cover the moment before its first frame; a translucent
        // backing would stack with the terminal's own.
        .background(ghostty.config.backgroundOpacity >= 1 ? ghostty.config.backgroundColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Shadows live on a sibling shape so SwiftUI doesn't have to shadow (and
        // re-composite) the live Metal terminal. The shape's interior is punched out
        // so only the shadow outside the card is drawn, never a fill behind it.
        .background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(isFocused ? 0.38 : 0.22), radius: isFocused ? 16 : 8, y: isFocused ? 6 : 3)
                    .shadow(color: Color.accentColor.opacity(isFocused ? 0.25 : 0), radius: 6)
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.2),
                              lineWidth: isFocused ? 1.5 : 1 / displayScale)
                .allowsHitTesting(false)
        }
        .overlay {
            if !isMaximized {
                ZStack {
                    ForEach(FloatResizeEdge.allCases) { edge in
                        FloatResizeHandle(edge: edge, frame: frame, containerSize: containerSize,
                                          focus: { controller.focusSurface(surface) }, update: update)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-pane-\(surface.id)")
        .accessibilityLabel("Floating terminal pane")
    }

    private var header: some View {
        HStack(spacing: 6) {
            titleArea
            HStack(spacing: 2) {
                FloatHeaderButton(systemImage: "rectangle.split.2x1", help: "Dock into split") {
                    controller.toggleFloatDock(surface)
                }
                FloatHeaderButton(systemImage: "minus", help: "Minimize to corner") {
                    controller.minimizeFloat(surface)
                }
                FloatHeaderButton(
                    systemImage: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: isMaximized ? "Restore size" : "Maximize"
                ) {
                    controller.toggleFloatMaximized(surface)
                }
                FloatHeaderButton(systemImage: "xmark", help: "Close floating pane", destructive: true) {
                    controller.closeSurface(surface)
                }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, headerTrailingInset)
        .frame(height: Self.headerHeight)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                if isFocused { Rectangle().fill(Color.accentColor.opacity(0.12)) }
            }
        }
        .floatChromeCursor()
    }

    /// The draggable part of the header. Move/focus/maximize gestures live here and
    /// not on the whole header, so they can't also fire for a button click (a focus
    /// after Minimize would immediately reveal the float again).
    private var titleArea: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)

            Text(surface.floatDisplayTitle)
                .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let directory = surface.floatDisplayDirectory {
                Text(directory)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(directory)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("floatingPanes"))
            .onChanged { value in
                if dragStart == nil {
                    dragStart = frame
                    controller.focusSurface(surface)
                }
                guard let start = dragStart else { return }
                update(start.offsetBy(dx: value.translation.width, dy: value.translation.height))
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            controller.toggleFloatMaximized(surface)
        })
        .simultaneousGesture(TapGesture().onEnded { controller.focusSurface(surface) })
        .help("Drag to move, double-click to maximize")
        .accessibilityAction(named: Text("Move left")) { update(frame.offsetBy(dx: -24, dy: 0)) }
        .accessibilityAction(named: Text("Move right")) { update(frame.offsetBy(dx: 24, dy: 0)) }
        .accessibilityAction(named: Text("Move up")) { update(frame.offsetBy(dx: 0, dy: -24)) }
        .accessibilityAction(named: Text("Move down")) { update(frame.offsetBy(dx: 0, dy: 24)) }
    }

    private func update(_ frame: CGRect) {
        controller.moveFloat(surface, to: FloatPane.normalized(frame, in: containerSize))
    }
}

private struct FloatHeaderButton: View {
    let systemImage: String
    let help: String
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(hovering ? (destructive ? Color.white : Color.primary) : Color.secondary)
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? (destructive ? Color.red.opacity(0.85) : Color.primary.opacity(0.12)) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Floating-pane pill

private struct TerminalFloatPill: View {
    @ObservedObject var controller: BaseTerminalController

    @State private var expanded = false
    @State private var paneToRestore: Ghostty.SurfaceView?
    @State private var pillHovered = false

    private var allCollapsed: Bool { controller.shownFloats.isEmpty }
    private var primaryAction: String {
        allCollapsed ? "Show all floating panes" : "Collapse all floating panes"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if allCollapsed { controller.restoreAllFloats() } else { controller.collapseAllFloats() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 13)
                    Text(controller.floats.count == 1 ? "1 float" : "\(controller.floats.count) floats")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .help(primaryAction)
            .accessibilityLabel(primaryAction)
            .accessibilityValue("\(controller.shownFloats.count) of \(controller.floats.count) visible")
            .accessibilityIdentifier("float-pill-toggle")

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 0.5, height: 12)
                .accessibilityHidden(true)

            Button {
                expanded.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .help("Manage floating panes")
            .accessibilityLabel("Manage floating panes")
            .accessibilityIdentifier("float-pill-manage")
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Show all floating panes") {
                        expanded = false
                        controller.restoreAllFloats()
                    }
                    .disabled(controller.collapsedFloats.isEmpty)
                    .accessibilityIdentifier("float-pill-show-all")
                    Divider()
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(controller.floats.reversed()) { pane in
                                TerminalFloatPillRow(controller: controller, surface: pane.surface,
                                                     isShown: controller.isFloatShown(pane.surface)) {
                                    paneToRestore = pane.surface
                                    expanded = false
                                }
                            }
                        }
                    }
                    .frame(height: min(280, CGFloat(controller.floats.count) * 35))
                }
                .buttonStyle(.plain)
                .padding(8)
                .frame(width: 260)
                .onExitCommand { expanded = false }
                .onDisappear {
                    guard let surface = paneToRestore else { return }
                    paneToRestore = nil
                    // Let AppKit restore its previous responder before focusing the selected pane.
                    DispatchQueue.main.async { controller.restoreFloat(surface) }
                }
                .floatChromeCursor()
            }
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(.regularMaterial))
        .overlay { Capsule().fill(Color.primary.opacity(pillHovered ? 0.08 : 0)).allowsHitTesting(false) }
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .onHover { pillHovered = $0 }
        .floatChromeCursor()
    }
}

private extension View {
    /// The terminal sets its I-beam on every mouse move (and the last cursor sticks
    /// when the pointer leaves it), so float chrome keeps reasserting the arrow.
    func floatChromeCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}

private struct TerminalFloatPillRow: View {
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var surface: Ghostty.SurfaceView
    let isShown: Bool

    let restore: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: restore) {
                HStack(spacing: 6) {
                    Image(systemName: isShown ? "eye" : "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(surface.floatDisplayTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let directory = surface.floatDisplayDirectory {
                            Text(directory)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isShown ? "Focus this floating pane" : "Show this floating pane")
            .accessibilityLabel(surface.floatDisplayTitle)
            .accessibilityValue(isShown ? "Visible" : "Collapsed")
            .accessibilityIdentifier("float-pill-pane-\(surface.id)")

            FloatHeaderButton(systemImage: "xmark", help: "Close floating pane", destructive: true) {
                controller.closeSurface(surface)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.22) : .clear)
        }
        .onHover { hovering = $0 }
    }
}

private extension Ghostty.SurfaceView {
    var floatDisplayTitle: String { title.isEmpty ? "Terminal" : title }

    /// The float's working directory (home abbreviated as `~`), or nil when unknown
    /// or already part of the title, as with shells that title the tab with the cwd.
    var floatDisplayDirectory: String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let directory = TerminalTabSidebarItem.abbreviate(path: pwd)
        if title.contains(directory) || title.contains(pwd) { return nil }
        return directory
    }
}

// MARK: - Resizing

enum FloatResizeEdge: CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

    var id: Self { self }
    var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var right: Bool { self == .right || self == .topRight || self == .bottomRight }
    var top: Bool { self == .top || self == .topLeft || self == .topRight }
    var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    func resizing(_ frame: CGRect, by translation: CGSize, in size: CGSize) -> CGRect {
        var result = frame
        if left {
            let x = min(max(0, frame.minX + translation.width), frame.maxX - min(240, size.width))
            result.origin.x = x
            result.size.width = frame.maxX - x
        }
        if right { result.size.width = min(max(min(240, size.width), frame.width + translation.width), size.width - frame.minX) }
        if top {
            let y = min(max(0, frame.minY + translation.height), frame.maxY - min(120, size.height))
            result.origin.y = y
            result.size.height = frame.maxY - y
        }
        if bottom { result.size.height = min(max(min(120, size.height), frame.height + translation.height), size.height - frame.minY) }
        return result
    }

    /// Resizes while keeping the frame's aspect ratio, like Shift-dragging a window.
    /// Corners scale from the opposite corner. Edges scale the other dimension too,
    /// keeping the top (left/right edges) or left (top/bottom edges) side fixed.
    func resizingKeepingAspect(_ frame: CGRect, by translation: CGSize, in size: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let widthScale = (frame.width + (left ? -translation.width : translation.width)) / frame.width
        let heightScale = (frame.height + (top ? -translation.height : translation.height)) / frame.height
        var scale: CGFloat
        switch self {
        case .left, .right: scale = widthScale
        case .top, .bottom: scale = heightScale
        default: scale = max(widthScale, heightScale)
        }

        // Fit inside the container on the sides that move, and respect the minimum size.
        let availableWidth = left ? frame.maxX : size.width - frame.minX
        let availableHeight = top ? frame.maxY : size.height - frame.minY
        let maxScale = min(availableWidth / frame.width, availableHeight / frame.height)
        let minScale = max(min(240, size.width) / frame.width, min(120, size.height) / frame.height)
        scale = min(max(scale, minScale), maxScale)

        let width = frame.width * scale, height = frame.height * scale
        return CGRect(x: left ? frame.maxX - width : frame.minX,
                      y: top ? frame.maxY - height : frame.minY,
                      width: width, height: height)
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            switch self {
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return Self.privateCursor("_windowResizeNorthWestSouthEastCursor")
        case .topRight, .bottomLeft: return Self.privateCursor("_windowResizeNorthEastSouthWestCursor")
        }
    }

    private static func privateCursor(_ name: String) -> NSCursor {
        let selector = Selector(name)
        let cursorClass: AnyObject = NSCursor.self
        guard cursorClass.responds(to: selector),
              let cursor = cursorClass.perform(selector)?.takeUnretainedValue() as? NSCursor else { return .crosshair }
        return cursor
    }
}

private struct FloatResizeHandle: View {
    let edge: FloatResizeEdge
    let frame: CGRect
    let containerSize: CGSize
    let focus: () -> Void
    let update: (CGRect) -> Void
    @State private var dragStart: CGRect?

    private var handleSize: CGSize {
        if edge == .left || edge == .right { return CGSize(width: 6, height: max(0, frame.height - 16)) }
        if edge == .top || edge == .bottom { return CGSize(width: max(0, frame.width - 16), height: 6) }
        return CGSize(width: 12, height: 12)
    }

    private var position: CGPoint {
        var point = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let inset: CGFloat = (edge.left || edge.right) && (edge.top || edge.bottom) ? 4 : 3
        if edge.left { point.x = inset }
        if edge.right { point.x = frame.width - inset }
        if edge.top { point.y = inset }
        if edge.bottom { point.y = frame.height - inset }
        return point
    }

    var body: some View {
        Color.clear
            .frame(width: handleSize.width, height: handleSize.height)
            .contentShape(Rectangle())
            // The terminal underneath sets its own cursor on mouse moves, so keep
            // reasserting ours while the pointer is over the handle.
            .onContinuousHover { phase in
                switch phase {
                case .active: edge.cursor.set()
                case .ended: if dragStart == nil { NSCursor.arrow.set() }
                }
            }
            .position(position)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("floatingPanes"))
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = frame
                        focus()
                    }
                    edge.cursor.set()
                    guard let start = dragStart else { return }
                    // Read live so pressing or releasing Shift mid-drag switches modes.
                    if NSEvent.modifierFlags.contains(.shift) {
                        update(edge.resizingKeepingAspect(start, by: value.translation, in: containerSize))
                    } else {
                        update(edge.resizing(start, by: value.translation, in: containerSize))
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    NSCursor.arrow.set()
                })
            .accessibilityLabel("Resize floating pane")
            .accessibilityAdjustableAction { direction in
                let amount: CGFloat = direction == .increment ? 10 : -10
                update(edge.resizing(frame, by: CGSize(width: amount, height: amount), in: containerSize))
            }
    }
}
