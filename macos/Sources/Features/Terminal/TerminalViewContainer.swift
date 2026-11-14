import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView = NSView()
    private let terminalHostingView: NSView

    /// Draws the rounded corner and edge stroke that make the terminal read as a sheet
    /// resting on the sidebar chrome. Pinned over the terminal content, below the sidebar.
    private let sheetEdgeView = TerminalSheetEdgeView()
    private var sheetEdgeMode: TerminalSheetEdgeMode = .hidden

    /// The sheet edge, exposed for layout tests.
    var sheetEdgeFrameView: NSView { sheetEdgeView }

    /// The optional tab sidebar placed on the leading edge, beside the terminal.
    private(set) var sidebarView: TerminalTabSidebarHostView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var sidebarTransitionID = 0
    private var terminalLeadingConstraint: NSLayoutConstraint!

    /// The narrowest the terminal is allowed to become because of the sidebar.
    static let minimumTerminalWidthBesideSidebar: CGFloat = 320

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalHostingView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalHostingView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        let terminalSize: NSSize
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            terminalSize = initialContentSize
        } else {
            terminalSize = hostingSize
        }

        // The configured window size describes the terminal, so a visible sidebar
        // adds to it rather than taking space from the terminal.
        return contentSize(fittingTerminal: terminalSize)
    }

    /// The content size that leaves `terminalSize` for the terminal, adding room for
    /// the sidebar when it's shown.
    func contentSize(fittingTerminal terminalSize: NSSize) -> NSSize {
        guard let sidebarView, sidebarView.isShown else { return terminalSize }
        return NSSize(width: terminalSize.width + sidebarView.preferredWidth, height: terminalSize.height)
    }

    /// Called after the glass background view is added or removed. Removal can be
    /// deferred past the config change that caused it.
    var glassEffectDidChange: (() -> Void)?

    private func setup() {
        wantsLayer = true
        // Animate an AppKit parent because NSHostingView manages its own layer geometry.
        terminalView.addSubview(terminalHostingView)
        terminalHostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalHostingView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            terminalHostingView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalHostingView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            terminalHostingView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
        ])
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalLeadingConstraint = terminalView.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalLeadingConstraint,
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // The edge lives inside the terminal's parent, above the terminal content,
        // so it inherits the terminal's slide and can never drift from it.
        sheetEdgeView.translatesAutoresizingMaskIntoConstraints = false
        sheetEdgeView.isHidden = true
        terminalView.addSubview(sheetEdgeView, positioned: .above, relativeTo: terminalHostingView)
        NSLayoutConstraint.activate([
            sheetEdgeView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            sheetEdgeView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            sheetEdgeView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            sheetEdgeView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
        ])
    }

    /// Style the sheet edge. It shows only while the sidebar is shown.
    ///
    /// - Parameter contentInset: The space the terminal grid always keeps from the
    ///   top and left edges. The corner shrinks to fit inside it so it never paints
    ///   over a cell.
    func updateSheetEdge(chrome: NSColor, stroke: NSColor, mode: TerminalSheetEdgeMode, contentInset: CGFloat) {
        sheetEdgeMode = mode
        sheetEdgeView.update(
            chrome: chrome,
            stroke: stroke,
            mode: mode,
            cornerRadius: Self.sheetCornerRadius(contentInset: contentInset))
        updateSheetEdgeVisibility()
    }

    /// The preferred radius of the sheet's top-left corner.
    static let preferredSheetCornerRadius: CGFloat = 10

    /// The largest corner radius, up to the preferred one, whose fill stays within
    /// `contentInset` of both edges. The fill reaches deepest along the diagonal,
    /// `r * (1 - 1/√2)` in from each edge, so content at `contentInset` is clear when
    /// `r <= contentInset / (1 - 1/√2)`.
    static func sheetCornerRadius(contentInset: CGFloat) -> CGFloat {
        let reach = 1 - 1 / CGFloat(2).squareRoot()
        let radius = min(preferredSheetCornerRadius, max(0, contentInset) / reach)
        // Too small to read as a corner; draw it square instead.
        return radius < 2 ? 0 : radius
    }

    /// The current corner radius, exposed for tests.
    var sheetCornerRadius: CGFloat { sheetEdgeView.cornerRadius }

    /// The edge follows the requested sidebar state, not the slide: the titlebar drops
    /// the chrome tone as soon as the sidebar starts collapsing, and an edge left
    /// until the slide ends would read as a separator under it.
    private func updateSheetEdgeVisibility() {
        let hidden = sheetEdgeMode == .hidden || sidebarView?.isShown != true
        if sheetEdgeView.isHidden != hidden { sheetEdgeView.isHidden = hidden }
    }

    // MARK: Sidebar

    /// Install the tab sidebar on the leading edge of the terminal.
    func installSidebar(_ sidebar: TerminalTabSidebarHostView) {
        guard sidebarView == nil else { return }
        sidebarView = sidebar

        addSubview(sidebar, positioned: .above, relativeTo: terminalView)
        let width = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidthConstraint = width
        let leading = sidebar.leadingAnchor.constraint(equalTo: leadingAnchor)
        sidebarLeadingConstraint = leading

        terminalLeadingConstraint.isActive = false
        terminalLeadingConstraint = terminalView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            width,
            terminalLeadingConstraint,
        ])

        setSidebarVisible(sidebar.isShown)
    }

    func setSidebarVisible(_ visible: Bool, animated: Bool = false) {
        guard let sidebarView else { return }
        let shouldAnimate = animated && sidebarView.isShown != visible && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        layoutSubtreeIfNeeded()
        let currentEdge = sidebarView.layer?.presentation()?.frame.maxX ?? sidebarView.frame.maxX
        sidebarView.isShown = visible
        sidebarView.isHidden = false
        sidebarTransitionID += 1
        let transitionID = sidebarTransitionID
        sidebarLayoutDidChange()
        layoutSubtreeIfNeeded()

        updateSheetEdgeVisibility()

        let animationKey = "sidebarVisibility"
        guard shouldAnimate else {
            sidebarView.layer?.removeAnimation(forKey: animationKey)
            terminalView.layer?.removeAnimation(forKey: animationKey)
            sidebarView.isHidden = !visible
            updateSheetEdgeVisibility()
            return
        }

        // Slide both parents equally after SwiftUI finishes resizing their contents.
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = currentEdge - sidebarView.frame.maxX
        animation.toValue = 0
        animation.duration = 0.2
        animation.timingFunction = .init(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.sidebarTransitionID == transitionID else { return }
            sidebarView.isHidden = !sidebarView.isShown
            self.updateSheetEdgeVisibility()
        }
        sidebarView.layer?.add(animation, forKey: animationKey)
        terminalView.layer?.add(animation, forKey: animationKey)
        CATransaction.commit()
    }

    /// Call when sidebar visibility or width changed.
    func sidebarLayoutDidChange() {
        invalidateIntrinsicContentSize()
        updateSidebarWidth()
        needsLayout = true
    }

    /// The width the sidebar actually occupies for a container width. The sidebar
    /// never squeezes the terminal below a usable width, but always keeps enough
    /// room for its own rows (never compacting them) unless the window is tiny.
    static func effectiveSidebarWidth(preferred: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let available = containerWidth - minimumTerminalWidthBesideSidebar
        let floor = min(TerminalTabSidebarPreferences.minimumWidth, containerWidth / 2)
        return max(min(preferred, available), floor).rounded()
    }

    private func updateSidebarWidth() {
        guard let sidebarView, let sidebarWidthConstraint, let sidebarLeadingConstraint else { return }
        // Keep rows at their full width while the sidebar slides beyond the window edge.
        let width = Self.effectiveSidebarWidth(preferred: sidebarView.preferredWidth, containerWidth: bounds.width)
        if sidebarWidthConstraint.constant != width {
            sidebarWidthConstraint.constant = width
        }
        let leading: CGFloat = sidebarView.isShown ? 0 : -width
        if sidebarLeadingConstraint.constant != leading {
            sidebarLeadingConstraint.constant = leading
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        updateSidebarWidth()
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: Sheet Edge

/// How the terminal's edge against the sidebar is drawn.
enum TerminalSheetEdgeMode: Equatable {
    /// A rounded top-left corner filled with chrome, and a stroke along the left
    /// edge, the corner arc and the top edge.
    case full
    /// The same stroke without the corner fill, for translucent windows where a fill
    /// would stack two translucent layers.
    case stroke
    /// Only a straight stroke along the left edge, for glass windows and styles whose
    /// titlebar the system draws.
    case leftEdge
    case hidden
}

/// Draws the sheet corner and stroke over the terminal. The terminal's own layer is
/// never masked: Metal surfaces live beneath it and the window background behind a
/// clipped corner is the terminal color, so the corner is painted on top instead.
private final class TerminalSheetEdgeView: NSView {
    private let cornerLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var mode: TerminalSheetEdgeMode = .hidden
    private(set) var cornerRadius: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for layer in [cornerLayer, strokeLayer] {
            layer.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
            self.layer?.addSublayer(layer)
        }
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = 1
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(chrome: NSColor, stroke: NSColor, mode: TerminalSheetEdgeMode, cornerRadius: CGFloat) {
        self.mode = mode
        self.cornerRadius = cornerRadius
        cornerLayer.fillColor = chrome.cgColor
        strokeLayer.strokeColor = stroke.cgColor
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        cornerLayer.contentsScale = scale
        strokeLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        cornerLayer.frame = bounds
        strokeLayer.frame = bounds

        // Layer coordinates have their origin at the bottom left.
        let width = bounds.width
        let top = bounds.height
        let radius = min(cornerRadius, width, top)
        let center = CGPoint(x: radius, y: top - radius)

        switch mode {
        case .hidden:
            cornerLayer.path = nil
            strokeLayer.path = nil

        case .leftEdge:
            cornerLayer.path = nil
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: top))
            strokeLayer.path = path

        case .full, .stroke:
            guard radius > 0 else {
                // No room for a corner: a square edge along the left and top.
                cornerLayer.path = nil
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: top - 0.5))
                path.addLine(to: CGPoint(x: width, y: top - 0.5))
                strokeLayer.path = path
                return
            }

            if mode == .full {
                // The square corner minus a quarter disc.
                let corner = CGMutablePath()
                corner.move(to: CGPoint(x: 0, y: top))
                corner.addLine(to: CGPoint(x: 0, y: top - radius))
                corner.addArc(center: center, radius: radius, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
                corner.closeSubpath()
                cornerLayer.path = corner
            } else {
                cornerLayer.path = nil
            }

            // Inset half a point so the 1pt line lands on whole pixels.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: top - radius))
            path.addArc(center: center, radius: radius - 0.5, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: width, y: top - 0.5))
            strokeLayer.path = path
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
        let hadGlass = glassEffectView != nil
        defer {
            if (glassEffectView != nil) != hadGlass { glassEffectDidChange?() }
        }

#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
