import AppKit
import SwiftUI

/// Owns only the drag preview. The native tab group changes once, after landing.
final class TerminalTabSidebarDrag: ObservableObject {
    enum Section: Hashable {
        case pinned
        case regular
        case snoozed
    }

    struct Target: Equatable {
        var section: Section
        var index: Int
    }

    struct Session {
        let id = UUID()
        let tab: TerminalTabSidebarModel.Tab
        let source: Target
        let counts: [Section: Int]
        let grabOffset: CGPoint
        let activationY: CGFloat
        var target: Target
        var isValid = true
        var settling = false

        var pinnedCount: Int { counts[.pinned, default: 0] }
        var pinnedShelfCount: Int { max(1, pinnedCount, count(in: .pinned)) }
        var usesPinTargets: Bool { source.section != .snoozed }

        func count(in section: Section) -> Int {
            var count = counts[section, default: 0]
            if source.section == section { count -= 1 }
            if target.section == section { count += 1 }
            return count
        }

        func projectedIndex(_ index: Int, in section: Section) -> Int {
            var result = index
            if source.section == section, index > source.index { result -= 1 }
            if target.section == section, result >= target.index { result += 1 }
            return result
        }
    }

    private struct Area {
        weak var viewport: NSView?
        weak var content: NSView?
    }

    static let spacing: CGFloat = 4
    static let padding: CGFloat = 6
    static let step = TerminalTabSidebarRow.height + spacing
    static let duration: TimeInterval = 0.16

    @Published private(set) var session: Session?
    weak var container: NSView?
    private var areas: [Section: Area] = [:]
    private var ghost: GhostView?
    private var monitor: Any?
    private var timer: Timer?
    private var pointer = CGPoint.zero
    private var previousPointerY: CGFloat = 0
    private var tracking = false
    private var revealTarget = false
    var reduceMotion = false
    private var commit: ((Target) -> Void)?

    var animation: Animation? { reduceMotion ? nil : .easeOut(duration: Self.duration) }

    func register(_ view: NSView, section: Section, content: Bool) {
        if content {
            areas[section, default: Area()].content = view
        } else {
            areas[section, default: Area()].viewport = view
        }
    }

    func begin(
        tab: TerminalTabSidebarModel.Tab,
        source: Target,
        counts: [Section: Int],
        gesture: DragGesture.Value,
        preview: AnyView,
        commit: @escaping (Target) -> Void
    ) {
        guard !tracking, session == nil, let container, let parent = container.window?.contentView,
              let content = areas[source.section]?.content else { return }
        let contentFrame = container.convert(content.bounds, from: content)
        let origin = CGPoint(x: contentFrame.minX + Self.padding,
            y: contentFrame.minY + Self.padding + CGFloat(source.index) * Self.step)
        let start = gesture.startLocation
        guard start.x < container.bounds.maxX - Self.padding - TerminalTabSidebarRow.trailingControlsWidth - 6 else {
            return
        }
        self.commit = commit
        self.pointer = gesture.location
        previousPointerY = start.y
        tracking = true
        session = Session(tab: tab, source: source, counts: counts,
            grabOffset: CGPoint(x: start.x - origin.x, y: start.y - origin.y),
            activationY: start.y, target: source)

        let ghost = GhostView(rootView: AnyView(preview.padding(12).accessibilityHidden(true)))
        ghost.setAccessibilityElement(false)
        parent.addSubview(ghost, positioned: .above, relativeTo: nil)
        self.ghost = ghost
        positionGhost()

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.tracking {
                self.finish(cancelled: true)
                return nil
            }
            if event.type == .leftMouseUp, let container = self.container {
                self.end(at: container.convert(event.locationInWindow, from: nil))
            } else if event.type == .leftMouseDragged, let container = self.container {
                self.update(container.convert(event.locationInWindow, from: nil))
            }
            return event
        }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.update(self.pointer)
            self.autoScroll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end(at location: CGPoint) {
        update(location)
        tracking = false
        finish(cancelled: false)
        removeMonitor()
    }

    private func update(_ location: CGPoint) {
        guard let session, !session.settling, let container else { return }
        // Keep vertical intent when the shelf grows beneath a stationary pointer.
        if location.y != pointer.y { previousPointerY = pointer.y }
        let previousY = previousPointerY
        pointer = location
        positionGhost()

        var target = session.target
        let valid: Bool
        if session.usesPinTargets {
            guard let pinned = areas[.pinned]?.viewport, let regular = areas[.regular]?.viewport else { return }
            let pinnedFrame = container.convert(pinned.bounds, from: pinned)
            let regularFrame = container.convert(regular.bounds, from: regular)
            valid = container.bounds.contains(location)
                && location.y >= pinnedFrame.minY - 26 && location.y <= regularFrame.maxY
            if valid {
                let boundary = (pinnedFrame.maxY + regularFrame.minY) / 2
                var pinThreshold = boundary - 6
                // Revealing an empty shelf must not pin the first row under a stationary pointer.
                if session.pinnedCount == 0, session.source.section == .regular {
                    pinThreshold = min(pinThreshold, session.activationY - 12)
                }
                target.section = Self.section(at: location.y, previousY: previousY,
                    current: target.section, pinThreshold: pinThreshold, unpinThreshold: boundary + 6)
            }
        } else {
            guard let viewport = areas[.snoozed]?.viewport else { return }
            valid = container.convert(viewport.bounds, from: viewport).contains(location)
        }
        if valid, let content = areas[target.section]?.content {
            let top = container.convert(content.bounds, from: content).minY
            let center = location.y - session.grabOffset.y + TerminalTabSidebarRow.height / 2
            let count = session.counts[target.section, default: 0]
            let remaining = count - (session.source.section == target.section ? 1 : 0)
            target.index = Self.insertionIndex(center: center, contentTop: top, count: remaining)
        }
        if target != session.target || valid != session.isValid {
            if target != session.target { revealTarget = target.section == .pinned }
            withAnimation(animation) {
                self.session?.target = target
                self.session?.isValid = valid
            }
        }
    }

    static func section(
        at y: CGFloat, previousY: CGFloat, current: Section, pinThreshold: CGFloat, unpinThreshold: CGFloat
    ) -> Section {
        if current == .regular, y < previousY, y < pinThreshold { return .pinned }
        if current == .pinned, y > previousY, y > unpinThreshold { return .regular }
        return current
    }

    static func insertionIndex(center: CGFloat, contentTop: CGFloat, count: Int) -> Int {
        min(max(Int(floor((center - contentTop - padding) / step)), 0), count)
    }

    private func positionGhost(at origin: CGPoint? = nil, animated: Bool = false) {
        guard let session, let container, let ghost, let parent = ghost.superview else { return }
        let origin = origin ?? CGPoint(x: pointer.x - session.grabOffset.x, y: pointer.y - session.grabOffset.y)
        let rect = CGRect(x: origin.x - 12, y: origin.y - 12,
            width: max(0, container.bounds.width - 2 * Self.padding) + 24,
            height: TerminalTabSidebarRow.height + 24)
        let frame = parent.convert(rect, from: container)
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ghost.animator().frame = frame
            }
        } else {
            ghost.frame = frame
        }
    }

    private func finish(cancelled: Bool) {
        guard let current = session, !current.settling else { return }
        revealTarget = false
        timer?.invalidate()
        timer = nil
        let accepted = !cancelled && current.isValid
        let target = accepted ? current.target : current.source
        withAnimation(animation) {
            session?.target = target
            session?.settling = true
        }
        if let container, let content = areas[target.section]?.content {
            let frame = container.convert(content.bounds, from: content)
            positionGhost(at: CGPoint(x: frame.minX + Self.padding,
                y: frame.minY + Self.padding + CGFloat(target.index) * Self.step), animated: true)
        }
        let delay = reduceMotion ? 0 : Self.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.session?.id == current.id else { return }
            let action = self.commit
            withAnimation(self.animation) {
                if accepted { action?(target) }
                self.ghost?.removeFromSuperview()
                self.ghost = nil
                self.session = nil
                self.commit = nil
            }
        }
    }

    func cancel() {
        finish(cancelled: true)
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        removeMonitor()
        ghost?.removeFromSuperview()
        ghost = nil
        session = nil
        commit = nil
        tracking = false
        revealTarget = false
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func autoScroll() {
        guard let session, !session.settling, session.isValid,
              let container, let content = areas[session.target.section]?.content,
              let viewport = areas[session.target.section]?.viewport,
              let scrollView = content.enclosingScrollView,
              let document = scrollView.documentView else { return }
        if revealTarget {
            revealTarget = false
            let slot = CGRect(x: Self.padding, y: Self.padding + CGFloat(session.target.index) * Self.step,
                width: max(0, content.bounds.width - 2 * Self.padding), height: TerminalTabSidebarRow.height)
            _ = document.scrollToVisible(document.convert(slot, from: content))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let frame = container.convert(viewport.bounds, from: viewport)
        let band = min(32, frame.height / 3)
        guard band > 0 else { return }
        var speed: CGFloat = 0
        if pointer.y < frame.minY + band {
            speed = -8 * min(1, max(0, (frame.minY + band - pointer.y) / band))
        } else if pointer.y > frame.maxY - band {
            speed = 8 * min(1, max(0, (pointer.y - frame.maxY + band) / band))
        }
        guard speed != 0 else { return }
        let clip = scrollView.contentView
        let y = min(max(clip.bounds.minY + speed, 0), max(0, document.bounds.height - clip.bounds.height))
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        update(pointer)
    }

    private final class GhostView: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// Geometry stays in AppKit so pointer movement doesn't publish layout on every frame.
struct TerminalTabSidebarDragAnchor: NSViewRepresentable {
    let drag: TerminalTabSidebarDrag
    var section: TerminalTabSidebarDrag.Section?
    var content = false
    var reduceMotion = false

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        if let section {
            drag.register(view, section: section, content: content)
        } else {
            drag.container = view
            drag.reduceMotion = reduceMotion
        }
    }

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
