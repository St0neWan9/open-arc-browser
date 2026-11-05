import AppKit
import OpenArcModel
import OpenArcDesign

// Arc's traffic lights (B160, B174). Observed on 2× Arc captures, [07 §2]:
// - Resting (window active or not): three plain 12 pt discs, a layer over the window color: black
//   ≈ 5.5–8 % on a dark-ink window (#C9C9DB on #DBDBEE, #CFCFE1 on #E1E1F3, #DDD8D6 on #EAE6E1),
//   white ≈ 27 % on a light-ink one (#9BB39E on #77937C). No rim, no glyph.
// - Hovering the group: all three grow to 14 pt and turn into the pre-macOS 26 window buttons with
//   their glyphs (✕ ≈ 7 pt wide with a ≈ 2 pt stroke, − 8 × 2 pt, the full-screen glyph a 6 pt square
//   cut along its rising diagonal). With the Graphite accent: an opaque neutral gray disc reading
//   #9F9F9D on screen, a half-point darker rim, white glyphs. The colored look for the other accents was not
//   captured; it uses the classic red / yellow / green (inferred).
//
// macOS 26 draws its own buttons in a newer style, so none of the system's drawing shows: the
// standard buttons stay in place, clickable and in the accessibility tree, fully transparent, and a
// mouse-transparent view in the same title bar view draws both looks over them.

/// What the traffic lights look like, independent of AppKit for the tests.
enum WindowButtonLook {
    enum Kind: CaseIterable { case close, minimize, zoom }

    /// Resting disc layer over the window. observed (see above); 7 % fits all three dark-ink
    /// readings within 4/255.
    static func restingDisc(lightInk: Bool) -> RGBAColor {
        lightInk ? RGBAColor(hex: 0xFFFFFF, alpha: 0.27) : RGBAColor(hex: 0x000000, alpha: 0.07)
    }

    /// Disc diameter while the group is hovered. observed (12 pt at rest, `Metrics.WindowButtons`).
    static let hoveredDiameter: CGFloat = 14

    struct Hovered: Equatable {
        var fill: RGBAColor
        var rim: RGBAColor
        var glyph: RGBAColor
    }

    /// The hovered button. Graphite observed; the colored ones are the classic macOS colors (inferred).
    static func hovered(_ kind: Kind, graphite: Bool) -> Hovered {
        if graphite {
            // Drawn a little darker than the reading: ours read ≈ 5/255 lighter on screen.
            return Hovered(fill: RGBAColor(hex: 0x9A9A98), rim: RGBAColor(hex: 0x000000, alpha: 0.22),
                           glyph: RGBAColor(hex: 0xFFFFFF))
        }
        switch kind {
        case .close:
            return Hovered(fill: RGBAColor(hex: 0xFF5F57), rim: RGBAColor(hex: 0xE0443E), glyph: RGBAColor(hex: 0x4D0000))
        case .minimize:
            return Hovered(fill: RGBAColor(hex: 0xFEBC2E), rim: RGBAColor(hex: 0xDEA123), glyph: RGBAColor(hex: 0x985712))
        case .zoom:
            return Hovered(fill: RGBAColor(hex: 0x28C840), rim: RGBAColor(hex: 0x1AAB29), glyph: RGBAColor(hex: 0x0A630F))
        }
    }

    /// Rim width of a hovered button. observed (one pixel at 2×).
    static let rimWidth: CGFloat = 0.5

    /// The system's Graphite accent (`AppleAccentColor` −1).
    static var systemUsesGraphite: Bool {
        (UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int) == -1
    }

    /// The glyph of `kind` in a disc of `diameter` centered on `center`, in a y-up space. Our own
    /// drawing in the measured sizes (for the 14 pt disc).
    static func glyphStroke(diameter d: CGFloat) -> CGFloat { d * 0.135 }

    static func glyph(_ kind: Kind, center c: CGPoint, diameter d: CGFloat) -> (path: CGPath, stroked: Bool) {
        let path = CGMutablePath()
        switch kind {
        case .close:
            let r = d * 0.195
            path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
            return (path, true)
        case .minimize:
            let w = d * 0.57, h = d * 0.143
            path.addRoundedRect(in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2)
            return (path, false)
        case .zoom:
            let s = d * 0.43, gap = d * 0.06
            let minX = c.x - s / 2, maxX = c.x + s / 2, minY = c.y - s / 2, maxY = c.y + s / 2
            // Upper-left triangle (right angle at the top left) and lower-right one.
            path.move(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX - gap * 1.4, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + gap * 1.4))
            path.closeSubpath()
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: minX + gap * 1.4, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - gap * 1.4))
            path.closeSubpath()
            return (path, false)
        }
    }
}

/// Draws the three buttons in their resting or hovered look and watches the pointer over them.
final class WindowButtonMuteView: NSView {
    /// Disc centers in this view's coordinates, one per button (close, minimize, zoom).
    var discCenters: [CGPoint] = [] { didSet { needsDisplay = true } }
    /// The window color takes light ink (`MainWindowChromeConfigurator.lightInk`).
    var usesLightInk = false { didSet { if usesLightInk != oldValue { needsDisplay = true } } }
    /// Called with true when the pointer enters the group, false when it leaves.
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var accentObserver: NSObjectProtocol?

    static let identifier = NSUserInterfaceItemIdentifier("openarc.windowButtonMute")

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let accentObserver { NotificationCenter.default.removeObserver(accentObserver) }
        accentObserver = nil
        guard window != nil else { return }
        // The accent color can change while the window is open.
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(hovered)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let graphite = WindowButtonLook.systemUsesGraphite
        for (center, kind) in zip(discCenters, WindowButtonLook.Kind.allCases) {
            let d = isHovered ? WindowButtonLook.hoveredDiameter : CGFloat(Metrics.WindowButtons.diameter)
            let disc = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            guard isHovered else {
                context.setFillColor(WindowButtonLook.restingDisc(lightInk: usesLightInk).cgColor)
                context.fillEllipse(in: disc)
                continue
            }
            let look = WindowButtonLook.hovered(kind, graphite: graphite)
            context.setFillColor(look.fill.cgColor)
            context.fillEllipse(in: disc)
            let rim = WindowButtonLook.rimWidth
            context.setStrokeColor(look.rim.cgColor)
            context.setLineWidth(rim)
            context.strokeEllipse(in: disc.insetBy(dx: rim / 2, dy: rim / 2))
            let glyph = WindowButtonLook.glyph(kind, center: center, diameter: d)
            context.addPath(glyph.path)
            if glyph.stroked {
                context.setStrokeColor(look.glyph.cgColor)
                context.setLineWidth(WindowButtonLook.glyphStroke(diameter: d))
                context.setLineCap(.round)
                context.strokePath()
            } else {
                context.setFillColor(look.glyph.cgColor)
                context.fillPath()
            }
        }
    }
}

private extension RGBAColor {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

extension MainWindowChromeConfigurator.Coordinator {
    /// Keeps the drawn buttons over the real ones. The real buttons stay transparent except in full
    /// screen, where the system's title bar shows them. `animated` moves the view with the buttons
    /// inside the caller's animation group. `lightInk` nil keeps the view's current ink.
    static func syncMute(in window: NSWindow, animated: Bool = false, targetOrigins: [CGPoint]? = nil, lightInk: Bool? = nil) {
        let buttons = WindowChromeLayout.buttonTypes.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let parent = buttons[0].superview else { return }
        let mute = (parent.subviews.first { $0.identifier == WindowButtonMuteView.identifier } as? WindowButtonMuteView)
            ?? {
                let view = WindowButtonMuteView()
                view.identifier = WindowButtonMuteView.identifier
                view.wantsLayer = true
                parent.addSubview(view, positioned: .above, relativeTo: buttons[2])
                return view
            }()
        if let lightInk { mute.usesLightInk = lightInk }
        let fullScreen = window.styleMask.contains(.fullScreen)
        let hidden = fullScreen || buttons[0].isHidden
        // Mid-animation the buttons' frames lag: follow the frames they are moving to.
        let frames = buttons.enumerated().map { index, button in
            guard let origins = targetOrigins, index < origins.count else { return button.frame }
            return CGRect(origin: origins[index], size: button.frame.size)
        }
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        if mute.frame != union {
            if animated { mute.animator().frame = union } else { mute.frame = union }
        }
        mute.discCenters = frames.map { CGPoint(x: $0.midX - union.minX, y: $0.midY - union.minY) }
        mute.isHidden = hidden
        let alpha: CGFloat = hidden ? 1 : 0
        for button in buttons where button.alphaValue != alpha { button.alphaValue = alpha }
    }
}
