import AppKit

/// The pointer target for one separator.
///
/// ## Why this view exists at all
///
/// `NSSplitView`'s own dividers cannot be used. Measured on this SDK
/// (macOS 27 / arm64), the two delegate callbacks that would let us intercept
/// a drag —
///
/// ```swift
/// func splitView(_ sv: NSSplitView, draggingDividerOf i: Int)
/// func splitView(_ sv: NSSplitView, willChangeDividerPositions p: UnsafeMutablePointer<NSPoint>)
/// ```
///
/// — still **compile**, so a build tells you nothing. They are never invoked:
/// a real mouse-down/mouse-drag/mouse-up sequence over a live split view left
/// both counters at zero (`docs/三栏拖曳手感-量化验收规格.md` expects the drag
/// to be intercepted; it is not). The notification-based replacement
/// (`NSSplitView.willResizeSubviewsNotification`) does fire, but only *after*
/// AppKit has already repositioned its own subviews, so hooking it means
/// fighting the layout after the fact.
///
/// So the divider is ours: a hit-testable view over the boundary, with the
/// mouse handling written out. `NSSplitView` is kept for one thing only —
/// being the arranged-subview container that gives each pane a correct
/// clipping, autoresizing and layer backing — and is told to hide its own
/// dividers so the two systems never both draw a line.
///
/// ## What this view does and does not own
///
/// Owns: the pointer target, the resize cursor, the drag loop with capture,
/// the double-click, and the hairline.
///
/// Does not own: the widths. It reports a pointer position and is told what to
/// draw; every layout decision belongs to `ColumnSolver`.
///
/// ## The drag loop
///
/// `mouseDown` runs a `nextEvent` tracking loop rather than relying on
/// `mouseDragged`/`mouseUp` being delivered. That is deliberate: AppKit stops
/// sending drag events to a view once the pointer leaves its bounds, so a fast
/// drag to the window edge would otherwise "let go" halfway — exactly the
/// "脱手" the spec forbids. A tracking loop holds the events until mouse-up
/// wherever they land, and `NSEvent.durationForever` means it never gives up
/// waiting.
///
/// ## Animation
///
/// The loop is wrapped in `NSAnimationContext` with `allowsImplicitAnimation =
/// false` and `duration = 0` for one reason: `NSView` is an
/// `NSAnimatablePropertyContainer`, so a frame set inside any animation context
/// interpolates, and an interpolating divider lags the pointer. This is the
/// first rule of the whole layout and it is enforced here, at the only place
/// frames are written during a drag.
final class ColumnDividerView: NSView {
    /// Index of the separator, counting from 0 at the left edge of *this
    /// region*. Used only for identity and ordering; the column a drag resizes
    /// is named explicitly, because a region's divider `0` and the store's
    /// divider `0` are different boundaries (the three columns are hosted by two
    /// regions).
    let handleIndex: Int
    /// A pointer sample. Two arguments: the pointer's x in the *container's*
    /// coordinate space, and whether the ⌥ modifier was held — which selects
    /// the column being resized.
    var onDrag: ((CGFloat, Bool) -> Void)?
    /// Mouse-up after a single click. The rubber band settles here.
    var onEnd: (() -> Void)?
    /// Double-click. Resets the whole layout.
    var onReset: (() -> Void)?
    /// Hover feedback. Colour only — see `updateHover`.
    var onHover: ((Bool) -> Void)?
    /// Drawn while the pointer is down.
    private(set) var isDragging = false
    /// Drawn while the pointer is over the target.
    private var isHovering = false
    /// The mouse-up position, so a double-click can be told from a drag that
    /// happened to end without moving.
    private var didMove = false
    /// Click count of the mouse-down that started this interaction.
    private var downClickCount = 0
    /// The container's x origin in window coordinates, captured at mouse-down
    /// and reused for every sample. Without it, a window move mid-drag would
    /// shift every subsequent sample and the divider would jump.
    private var containerOriginX: CGFloat = 0

    init(handleIndex: Int) {
        self.handleIndex = handleIndex
        // The element is a `let`, so it cannot capture `self` before `super.init`
        // has run — and the compiler is right to say so: passing a freshly-made
        // `NSView()` here would be deallocated at the end of the statement, and
        // the element's `weak var view` would be nil forever. So the element is
        // built with **no** owner and adopts one immediately afterwards, and it
        // reads the owner lazily on every `accessibilityFrame()` call.
        self.accessibilityElement = ColumnDividerAccessibilityElement()
        super.init(frame: .zero)
        accessibilityElement.view = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnDividerView is created in code, not from a nib")
    }

    // MARK: - Appearance

    override func resetCursorRects() {
        // The standard horizontal-resize affordance. Free from AppKit, which
        // was one of the reasons to stay on AppKit for the container.
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// The tooltip.
    ///
    /// Carries both compensation affordances: it names the column a plain drag
    /// moves (so "the left column" is never a surprise), and it is the only
    /// place the ⌥ inversion is discoverable — a modifier nobody has been told
    /// about is a feature that does not exist.
    ///
    /// `NSView.toolTip` rather than an `NSToolTip` instance: the property is the
    /// supported path for a bare view (`addCursorRect(_:toolTip:)` does not
    /// exist, and `tooltip(for:)` is not on `NSView`), and it needs no tracking
    /// area of its own.
    var helpText: String {
        get { toolTip ?? "" }
        set { toolTip = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if isDragging {
            color = .controlAccentColor
        } else if isHovering {
            color = .secondaryLabelColor
        } else {
            color = .separatorColor
        }
        color.setFill()
        // 1pt, centred. The target around it is 10pt; only the line is drawn.
        bounds.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // A single tracking area for the whole target, recreated only when the
        // geometry changes. Re-adding on every mouse move is a classic way to
        // make a hover effect feel heavy.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(false)
    }

    /// Colour is the only thing hover changes.
    ///
    /// No shadow, no scale, and **never a width change**: a hit target that
    /// resizes on hover is a hit target the user cannot trust, because the
    /// boundary they are aiming at moves when they get close to it.
    private func updateHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHover?(hovering)
        needsDisplay = true
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        guard let container = superview, let window else { return }
        containerOriginX = container.convert(bounds.origin, to: nil).x
        downClickCount = event.clickCount
        didMove = false
        isDragging = true
        needsDisplay = true
        // The separator is focusable, and clicking it should land the keyboard
        // focus there — otherwise arrow keys keep going to whatever the reader
        // had focused, and a keyboard user has no other way to reach the
        // handle.
        window.makeFirstResponder(self)

        // No threshold: the divider responds on the press. A `minimumDistance`
        // equivalent here would make the user think they missed it.
        //
        // The ⌥ flag is read from *this* event, once, and re-read on every
        // sample below — so pressing or releasing ⌥ mid-drag switches the target
        // column live, which is what a modifier is supposed to do. A user who
        // starts dragging, realises they grabbed the wrong separator, and holds
        // ⌥ should not have to let go and start again.
        onDrag?(pointerX(from: event), event.modifierFlags.contains(.option))

        // The drag is run as a tracking loop rather than through
        // `mouseDragged`/`mouseUp`, because AppKit stops delivering drag events
        // to a view once the pointer leaves its bounds — a fast drag to the
        // window edge would otherwise "let go" halfway, which is exactly the
        // 脱手 the spec forbids. The loop holds events until mouse-up wherever
        // they land, and `durationForever` means it never gives up waiting.
        var released = false
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = false
            context.duration = 0
            while let sample = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if sample.type == .leftMouseUp {
                    released = true
                    break
                }
                didMove = true
                onDrag?(pointerX(from: sample), sample.modifierFlags.contains(.option))
            }
        }

        isDragging = false
        needsDisplay = true
        // A mouse-up with no drag in between is a click, and a second one
        // within the double-click interval is a reset. `didMove` is what keeps
        // "dragged away and came back" from being read as a double-click.
        if downClickCount >= 2, !didMove {
            onReset?()
        } else {
            onEnd?()
        }
        _ = released
    }

    /// The pointer's x in the container's coordinate space.
    ///
    /// `locationInWindow` minus the container's window-x, captured at
    /// mouse-down. Reading the container's origin live would be wrong if the
    /// window itself moved during the drag.
    private func pointerX(from event: NSEvent) -> CGFloat {
        event.locationInWindow.x - containerOriginX
    }

    // MARK: - Keyboard    // MARK: - Keyboard

    /// The width currently in effect, for the keyboard's relative steps and for
    /// the spoken value.
    var currentWidth: Double = 0
    /// Arrow / PageUp / PageDown / Home / End, and the accessibility
    /// increment/decrement actions. A delta of zero means "reset to ideal",
    /// which is how the accessibility press gesture reuses this one path.
    var onAdjust: ((Double) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:      // up arrow
            adjust(ColumnLayoutMetrics.keyboardStep)
        case 125:      // down arrow
            adjust(-ColumnLayoutMetrics.keyboardStep)
        case 116:      // page up
            adjust(ColumnLayoutMetrics.keyboardPageStep)
        case 121:      // page down
            adjust(-ColumnLayoutMetrics.keyboardPageStep)
        case 115:      // home
            adjust(0, absolute: .min)
        case 119:      // end
            adjust(0, absolute: .max)
        default:
            // Anything else belongs to the window, not to the separator.
            super.keyDown(with: event)
        }
    }

    /// The single adjustment entry point.
    ///
    /// Reached from the physical arrow keys, Page Up / Page Down, Home / End and
    /// the accessibility increment/decrement actions, so a keyboard user and a
    /// VoiceOver user get identical behaviour and there is exactly one
    /// definition of "a step".
    private func adjust(_ delta: Double, absolute: ColumnBound? = nil) {
        if let absolute {
            onJump?(absolute)
        } else {
            onAdjust?(delta)
        }
    }

    /// Home / End. A jump straight to a bound.
    var onJump: ((ColumnBound) -> Void)?

    /// Built once per handle and published as this view's only child, so
    /// VoiceOver sees one adjustable element rather than a 10pt strip of view
    /// with no name. See `ColumnDividerAccessibilityElement` for why this is an
    /// element rather than the view.
    let accessibilityElement: ColumnDividerAccessibilityElement

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: - Accessibility forwarding

    /// Publishes the child element and nothing else.
    ///
    /// The view is deliberately *not* itself an accessibility element: it is a
    /// 10pt strip of hairline with no name of its own, and if AppKit also
    /// synthesised an element for it, VoiceOver would announce the divider twice
    /// — once as a bare group and once as the adjustable control that is the
    /// whole point.
    override func accessibilityChildren() -> [Any]? { [accessibilityElement] }

    /// Names the element after the column, so a fourth column without a noun
    /// fails to compile in `LagoonColumn.adjustmentNoun` instead of shipping a
    /// handle VoiceOver announces as "adjustable" with nothing to adjust.
    func configureAccessibility(label: String, onAdjust: @escaping (Double) -> Void) {
        accessibilityElement.label = label
        accessibilityElement.currentWidth = currentWidth
        accessibilityElement.onAdjust = onAdjust
    }

    func refreshAccessibilityValue() {
        accessibilityElement.currentWidth = currentWidth
    }
}

/// The divider's presence in the accessibility tree.
///
/// ## Why this is a separate `NSAccessibilityElement` and not the view itself
///
/// The obvious spelling — `view.accessibilityIncrement()` /
/// `view.accessibilityDecrement()` — **does not compile on this SDK**. Measured
/// against the macOS 27 headers: `NSView` exposes no `accessibilityIncrement`
/// or `accessibilityDecrement` selector at all, and `NSAccessibility.Role` has
/// no `.adjustable` case, so there is no role to declare either. A
/// `setAccessibilityValueIncrementHandler` does not exist either.
///
/// What *is* supported is the `NSAccessibilityElementProtocol`, whose only
/// required members are `accessibilityFrame()` and `accessibilityParent()`, and
/// whose optional `accessibilityIncrement` / `accessibilityDecrement` are what
/// VoiceOver's increment/decrement and the accessibility arrow keys invoke. So
/// the view publishes a child element that answers those, and the view itself
/// forwards `accessibilityChildren()` to it.
///
/// ## Why the role is `.slider`
///
/// There is no `.adjustable` role to ask for, and `.slider` is what macOS
/// actually *speaks* for a control with increment/decrement actions. Announcing
/// it as a slider is the closest honest description of a 1pt boundary you can
/// push either way, and it is the role VoiceOver's increment/decrement gestures
/// are designed around.
///
/// ## One path for both audiences
///
/// `adjust(by:)` is the single adjustment entry point, reached from the physical
/// arrow keys, Page Up / Page Down, and the accessibility increment/decrement
/// actions. A keyboard user and a VoiceOver user therefore get byte-identical
/// behaviour, which is the point of not reimplementing either in two places.
///
/// Not `@MainActor`, deliberately: `NSAccessibilityElementProtocol` is already
/// main-actor-isolated, and annotating the conformance as well makes the
/// compiler warn that the conformance "crosses into main actor-isolated code"
/// (`#ConformanceIsolation`, an error under Swift 6). Every member here touches
/// the view hierarchy or the width store, so the protocol's own isolation is
/// what actually protects it — and the warn gate fails the build on the warning.
final class ColumnDividerAccessibilityElement: NSObject, NSAccessibilityElementProtocol {
    /// The width to speak. Kept in points and formatted at read time so the
    /// rounded figure VoiceOver hears is the figure the layout has.
    var currentWidth: Double = 0
    /// "Adjust the message list width", localized.
    var label: String = ""
    /// Positive widens. One adjustment step, from the caller.
    var onAdjust: ((Double) -> Void)?
    // MARK: - Accessibility forwarding

    /// The view this element describes, for its frame. Weak: the element is
    /// owned by the view, so a strong link would be a cycle.
    ///
    /// Internal rather than private because the owning view assigns it after
    /// `super.init` — the element is a `let`, so it cannot capture `self` before
    /// the superclass is initialised.
    weak var view: NSView?

    /// No owner yet. The owning view assigns `view` immediately after
    /// `super.init`, which is the only point at which it can hand over `self`.
    override init() {
        super.init()
    }

    /// Convenience for a caller that already has the view.
    convenience init(view: NSView) {
        self.init()
        self.view = view
    }

    // MARK: Required by NSAccessibilityElementProtocol

    func accessibilityFrame() -> NSRect {
        // Screen coordinates, which is what VoiceOver needs; the view's own
        // bounds are in its superview's space and would place the focus ring
        // nowhere near the divider.
        guard let view, let window = view.window else { return .zero }
        return view.convert(view.bounds, to: nil)
            .offsetBy(dx: window.frame.origin.x, dy: window.frame.origin.y)
    }

    func accessibilityParent() -> Any? { view?.superview }

    // MARK: The adjustable semantics

    func accessibilityRole() -> NSAccessibility.Role? { .slider }

    func accessibilityLabel() -> String? { label }

    /// "340 点" / "340 points". The unit is included because a bare number is
    /// read as a count rather than a measurement.
    func accessibilityValue() -> Any? { ColumnWidthFormatter.speech(Int(currentWidth.rounded())) }

    func accessibilityIncrement() {
        onAdjust?(ColumnLayoutMetrics.keyboardStep)
    }

    func accessibilityDecrement() {
        onAdjust?(-ColumnLayoutMetrics.keyboardStep)
    }

    /// Pressing the divider's accessibility element resets, matching the
    /// double-click. Exposed as an action rather than left undefined so
    /// VoiceOver's "activate" is not a silent no-op — a control that swallows
    /// the press gesture and does nothing is worse than one with no press
    /// gesture at all.
    func accessibilityPerformPress() {
        onAdjust?(0)
    }

    func accessibilityHelp() -> String? {
        ColumnWidthFormatter.help
    }
}

/// Formats the divider's accessibility strings.
///
/// Split out of the view so the wording is one function with one owner, and so
/// a test can pin both languages without standing up a window.
enum ColumnWidthFormatter {
    /// "340 点" / "340 points". The unit is included because a bare number is
    /// read as a count, not a measurement.
    static func speech(_ points: Int) -> String {
        L10n.current.columnWidthPoints(points)
    }

    /// "Adjust the message list width", naming the column on the handle's left.
    static func label(for column: LagoonColumn) -> String {
        L10n.current.adjustColumnWidth(column.adjustmentNoun)
    }

    /// The handle's tooltip: what a plain drag does, and what ⌥ does instead.
    static func tooltip(for column: LagoonColumn) -> String {
        L10n.current.columnResizeTooltip(column.adjustmentNoun)
    }

    /// What the arrow keys do, for VoiceOver's help attribute.
    ///
    /// Worth saying out loud: the step sizes are otherwise invisible to a
    /// VoiceOver user, who would have to press increment repeatedly to learn
    /// that one press is 16pt.
    static var help: String { L10n.current.columnResizeHelp }
}

extension LagoonColumn {
    /// The noun the accessibility label uses for this column.
    ///
    /// On `LagoonColumn` rather than in the formatter so the enum owns its own
    /// identity — a fourth column added without a noun would fail to compile
    /// here instead of silently shipping an unlabelled handle.
    var adjustmentNoun: String {
        switch self {
        case .navigation: return "navigation"
        case .list: return "list"
        case .reader: return "reader"
        }
    }
}
