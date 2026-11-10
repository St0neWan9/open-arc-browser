import SwiftUI
import AppKit
import Combine
import QuartzCore
import OpenArcModel
import OpenArcDesign

// The window background between two Spaces while the sidebar pages slide (issue #15, plan B195).
// The colors are a function of where the pages are: they leave the current Space's colors as its
// page starts to move and reach the target Space's when the pages are half way (user, 2026-11-09:
// "at the midline it is basically the target Space's color"). One Core Animation gradient layer
// paints them, set directly from the swipe or the settle's display frames: no SwiftUI view updates
// per frame.

/// The blend's curve and timing.
enum SpaceBlend {
    /// Share of the way across at which the background shows the target's colors. User
    /// requirement (2026-11-09); Arc's own curve was not sampled (unknown).
    static let fullBlendFraction: Double = 0.5

    /// How far the background is from the start colors (0) to the target's (1) when the pages have
    /// travelled `travel` points of `width`, the blend having begun at `start`. Smoothstep over the
    /// first `fullBlendFraction` of the way, so the color starts and arrives without a kink.
    static func progress(travel: CGFloat, start: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        // The page is already in place.
        let span = Double(width - start)
        guard span > 0 else { return 1 }
        let f = min(max(Double(travel - start) / span / fullBlendFraction, 0), 1)
        return f * f * (3 - 2 * f)
    }

    /// The share of a settle the pages have covered after `elapsed` seconds on the Space-switch
    /// spring ([07 §11] observed: critically damped, response 0.2 s, unit mass, starting at rest),
    /// 1 once they are at rest (within a thousandth of the way).

    static func springFraction(elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard elapsed.isFinite else { return 1 }
        let constants = Motion.spaceSwitch.curve.springConstants ?? (stiffness: 987, damping: 62.8)
        let omega = constants.stiffness.squareRoot()
        let zeta = constants.damping / (2 * omega)
        let remaining: Double
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            remaining = exp(-zeta * omega * elapsed)
                * (cos(damped * elapsed) + zeta * omega / damped * sin(damped * elapsed))
        } else {
            // Critically damped (the token); a stiffer damping is drawn the same way.
            remaining = (1 + omega * elapsed) * exp(-omega * elapsed)
        }
        return abs(remaining) < 0.001 ? 1 : 1 - remaining
    }

    /// Seconds until `springFraction` reaches 1.
    static var springSettleTime: Double {
        var t = 0.0
        while springFraction(elapsed: t) < 1, t < 2 { t += 1.0 / 240 }
        return t
    }
}

/// Calls a closure on every display frame of the main screen until it returns false.
@MainActor
enum DisplayFrames {
    static func run(_ tick: @escaping @MainActor (Double) -> Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            _ = tick(.infinity)
            return
        }
        DisplayFrameTarget(tick: tick).start(on: screen)
    }
}

/// The display link's target; the link keeps it alive until it is invalidated.
@MainActor
private final class DisplayFrameTarget: NSObject {
    private let tick: @MainActor (Double) -> Bool
    private let startTime = CACurrentMediaTime()

    init(tick: @escaping @MainActor (Double) -> Bool) {
        self.tick = tick
    }

    func start(on screen: NSScreen) {
        screen.displayLink(target: self, selector: #selector(step(_:))).add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        if !tick(link.targetTimestamp - startTime) { link.invalidate() }
    }
}

/// What the window background paints over the blur: one color, or a gradient along an axis.
struct WindowPaint: Equatable {
    /// At least one color; one per location.
    var colors: [RGBAColor]
    var locations: [Double]
    /// In SwiftUI unit coordinates (y down). Unused for one color.
    var axis: GradientAxis

    init(colors: [RGBAColor], locations: [Double], axis: GradientAxis) {
        self.colors = colors
        self.locations = locations
        self.axis = axis
    }

    /// The colors `WindowBackgroundView` paints for `palette` on `surface`.
    @MainActor init(palette: ThemePalette, surface: WindowSurface) {
        let colors = WindowBackgroundView(palette: palette, surface: surface).paintedColors
        self.colors = colors.isEmpty ? [palette.windowBackground] : colors
        locations = WindowBackgroundView.stops(self.colors, locations: palette.backgroundGradientLocations)
            .map { Double($0.location) }
        axis = palette.backgroundGradientAxis
    }

    /// The color at `location` along the axis, linear between the stops.
    func color(at location: Double) -> RGBAColor {
        guard let first = colors.first else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        guard colors.count > 1, let lastLocation = locations.last, location > locations[0] else { return first }
        guard location < lastLocation else { return colors[colors.count - 1] }
        let upper = locations.firstIndex { $0 >= location } ?? colors.count - 1
        let lower = upper - 1
        let span = locations[upper] - locations[lower]
        let t = span > 0 ? (location - locations[lower]) / span : 1
        return RGBAColor(red: colors[lower].red + (colors[upper].red - colors[lower].red) * t,
                         green: colors[lower].green + (colors[upper].green - colors[lower].green) * t,
                         blue: colors[lower].blue + (colors[upper].blue - colors[lower].blue) * t,
                         alpha: colors[lower].alpha + (colors[upper].alpha - colors[lower].alpha) * t)
    }

    /// `a` blended toward `b` by `t`. Each color mixes premultiplied, which is what a cross-fade of
    /// the two paints over the same blur shows (the colors are translucent on a see-through
    /// window); stacking one translucent paint on the other would let `a` show through `b`.
    /// Gradients are sampled at both paints' stops; the axis turns from `a`'s to `b`'s.
    static func blend(_ a: WindowPaint, _ b: WindowPaint, _ t: Double) -> WindowPaint {
        guard t > 0 else { return a }
        guard t < 1 else { return b }
        let locations = a.colors.count == 1 && b.colors.count == 1 ? [0] : Set(a.locations + b.locations).sorted()
        let axis: GradientAxis
        if a.colors.count == 1 {
            axis = b.axis
        } else if b.colors.count == 1 {
            axis = a.axis
        } else {
            axis = GradientAxis(startX: a.axis.startX + (b.axis.startX - a.axis.startX) * t,
                                startY: a.axis.startY + (b.axis.startY - a.axis.startY) * t,
                                endX: a.axis.endX + (b.axis.endX - a.axis.endX) * t,
                                endY: a.axis.endY + (b.axis.endY - a.axis.endY) * t)
        }
        return WindowPaint(colors: locations.map { mix(a.color(at: $0), b.color(at: $0), t) },
                           locations: locations, axis: axis)
    }

    /// Premultiplied mix of two colors, returned straight.
    static func mix(_ x: RGBAColor, _ y: RGBAColor, _ t: Double) -> RGBAColor {
        let alpha = x.alpha + (y.alpha - x.alpha) * t
        guard alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        func channel(_ cx: Double, _ cy: Double) -> Double {
            (cx * x.alpha * (1 - t) + cy * y.alpha * t) / alpha
        }
        return RGBAColor(red: channel(x.red, y.red), green: channel(x.green, y.green),
                         blue: channel(x.blue, y.blue), alpha: alpha)
    }
}

/// The window background's colors (`WindowBackgroundView` minus the blur and the grain), which
/// blend between Spaces while the sidebar pages slide.
struct SpaceBlendBackground: NSViewRepresentable {
    let sidebar: SidebarViewModel
    /// What the selected Space paints when no blend runs.
    let paint: WindowPaint
    let surface: WindowSurface

    func makeNSView(context: Context) -> SpaceBlendPaintView {
        let view = SpaceBlendPaintView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SpaceBlendPaintView, context: Context) {
        nsView.update(sidebar: sidebar, idle: paint, surface: surface)
    }
}

/// Paints `WindowPaint`s on its gradient layer; follows the blend of the sidebar's `spaceSwipe`.
@MainActor
final class SpaceBlendPaintView: NSView {
    private weak var sidebar: SidebarViewModel?
    private var idle: WindowPaint?
    private var surface: WindowSurface = .opaque
    /// What the layer paints now.
    private(set) var shown: WindowPaint?
    /// The colors on screen when the running blend began, and that blend's `blendGeneration`.
    private var from: WindowPaint?
    private var fromGeneration: Int?
    /// The running blend's target and its paint, computed once per blend.
    private var target: (id: UUID, generation: Int, paint: WindowPaint)?
    private var blendChanges: AnyCancellable?
    /// The settle whose colors run as a layer animation (`SpaceSwipeState.settleRun`).
    private var animatedSettleID: Int?
    static let animationKey = "openarc.spaceBlend.settle"
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { gradient }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(sidebar: SidebarViewModel, idle: WindowPaint, surface: WindowSurface) {
        if self.sidebar !== sidebar {
            self.sidebar = sidebar
            blendChanges = sidebar.spaceSwipe.blendChanges.sink { [weak self] in
                // Sent on the main actor by `SpaceSwipeState`.
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if self.surface != surface {
            self.surface = surface
            target = nil
        }
        self.idle = idle
        refresh()
    }

    /// Paints the selected Space's colors, or the running blend.
    func refresh() {
        guard let idle else { return }
        guard let sidebar, let targetID = sidebar.spaceSwipe.blendTargetSpaceID else {
            from = nil
            target = nil
            stopSettleAnimation()
            apply(idle)
            return
        }
        let swipe = sidebar.spaceSwipe
        if fromGeneration != swipe.blendGeneration {
            fromGeneration = swipe.blendGeneration
            from = shown ?? idle
        }
        if target?.id != targetID || target?.generation != swipe.blendGeneration {
            target = (targetID, swipe.blendGeneration,
                      WindowPaint(palette: sidebar.palette(forSpace: targetID), surface: surface))
        }
        guard let target else { return }
        let start = from ?? idle
        apply(.blend(start, target.paint, swipe.blendProgress))
        if let run = swipe.settleRun {
            if animatedSettleID != run.id {
                animatedSettleID = run.id
                animateSettle(run, swipe: swipe, from: start, to: target.paint)
            }
        } else {
            stopSettleAnimation()
        }
    }

    /// The settle's colors as keyframes on the Space-switch spring, added in the same transaction as
    /// the pages' spring so both start on the same frame (B208). The per-frame model updates still
    /// run underneath; the animation is what shows.
    private func animateSettle(_ run: (id: Int, from: CGFloat, to: CGFloat), swipe: SpaceSwipeState,
                               from start: WindowPaint, to end: WindowPaint) {
        let duration = SpaceBlend.springSettleTime
        let steps = max(2, Int((duration * 60).rounded()))
        // Kept off the exact ends so every keyframe has the same stops and they interpolate.
        let paints = (0...steps).map { step -> WindowPaint in
            let t = duration * Double(step) / Double(steps)
            let travel = run.from + (run.to - run.from) * CGFloat(SpaceBlend.springFraction(elapsed: t))
            let p = min(max(swipe.blendProgress(atTravel: travel), 0.0001), 0.9999)
            return .blend(start, end, p)
        }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.calculationMode = .linear
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [
            keyframes("colors", paints.map { Self.layerColors($0) }),
            keyframes("locations", paints.map { Self.layerLocations($0) }),
            keyframes("startPoint", paints.map { NSValue(point: Self.layerPoint(x: $0.axis.startX, y: $0.axis.startY)) }),
            keyframes("endPoint", paints.map { NSValue(point: Self.layerPoint(x: $0.axis.endX, y: $0.axis.endY)) }),
        ]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        gradient.add(group, forKey: Self.animationKey)
    }

    private func stopSettleAnimation() {
        guard animatedSettleID != nil else { return }
        animatedSettleID = nil
        gradient.removeAnimation(forKey: Self.animationKey)
    }

    static func layerColors(_ paint: WindowPaint) -> [CGColor] {
        let colors = paint.colors.count == 1 ? [paint.colors[0], paint.colors[0]] : paint.colors
        return colors.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
    }

    static func layerLocations(_ paint: WindowPaint) -> [NSNumber] {
        (paint.colors.count == 1 ? [0, 1] : paint.locations).map { NSNumber(value: $0) }
    }

    /// For tests: the running settle animation, if any.
    var settleAnimationForTesting: CAAnimation? { gradient.animation(forKey: Self.animationKey) }

    private func apply(_ paint: WindowPaint) {
        guard paint != shown else { return }
        shown = paint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = Self.layerColors(paint)
        gradient.locations = Self.layerLocations(paint)
        gradient.startPoint = Self.layerPoint(x: paint.axis.startX, y: paint.axis.startY)
        gradient.endPoint = Self.layerPoint(x: paint.axis.endX, y: paint.axis.endY)
        CATransaction.commit()
    }

    /// A SwiftUI unit point (y down) in the layer's unit space (y up: the view is not flipped).
    static func layerPoint(x: Double, y: Double) -> CGPoint { CGPoint(x: x, y: 1 - y) }

    /// For tests: the gradient layer.
    var gradientLayerForTesting: CAGradientLayer { gradient }
}
