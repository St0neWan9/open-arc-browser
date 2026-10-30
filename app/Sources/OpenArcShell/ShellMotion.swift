import SwiftUI
import QuartzCore
import OpenArcDesign

// SwiftUI and Core Animation forms of the motion tokens in `OpenArcDesign.Motion`
// ([07 §11 动效(E7)]). Every animated surface reads its animation from `ShellMotion`, so the
// tests can pin each one against its token.

extension MotionCurve {
    /// The SwiftUI animation of this curve; nil for `instant` (no animation).
    var swiftUI: Animation? {
        switch self {
        case .instant:
            return nil
        case let .spring(response, fraction):
            return .spring(response: response, dampingFraction: fraction)
        case let .timingCurve(x1, y1, x2, y2, duration):
            return .timingCurve(x1, y1, x2, y2, duration: duration)
        case .easeOut(let duration):
            return .easeOut(duration: duration)
        case .easeInOut(let duration):
            return .easeInOut(duration: duration)
        }
    }

    /// Core Animation timing function for `NSAnimationContext` (timed curves only; a spring maps
    /// to nil and callers fall back to its nominal duration with the default curve).
    var mediaTimingFunction: CAMediaTimingFunction? {
        switch self {
        case let .timingCurve(x1, y1, x2, y2, _):
            return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        case .easeOut:
            return CAMediaTimingFunction(name: .easeOut)
        case .easeInOut:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        case .instant, .spring:
            return nil
        }
    }
}

/// The animations the shell applies, one per surface. [07 §11]
enum ShellMotion {
    /// Space switch: horizontal paging, no fade. `Motion.spaceSwitch`.
    static var spaceSwitch: Animation? { Motion.spaceSwitch.curve.swiftUI }
    /// Leaving the Create Space view. `Motion.spaceCreateFade` ([06 §1]).
    static var spaceCreateFade: Animation? { Motion.spaceCreateFade.curve.swiftUI }
    /// ⌘S sidebar hide/show, web panel resize and sidebar slide. `Motion.sidebarToggle`.
    static var sidebarToggle: Animation? { Motion.sidebarToggle.curve.swiftUI }
    /// Peek panel slide. `Motion.sidebarPeekSlide` (unknown).
    static var sidebarPeekSlide: Animation? { Motion.sidebarPeekSlide.curve.swiftUI }
    /// Favorites making room for a drag. `Motion.favoriteMakeRoom` (unknown).
    static var favoriteMakeRoom: Animation? { Motion.favoriteMakeRoom.curve.swiftUI }
    /// Sidebar list scroller fade on hover. `Motion.sidebarScrollerFade` (unknown, B89).
    static var sidebarScrollerFade: Animation? { Motion.sidebarScrollerFade.curve.swiftUI }
    /// Little Arc content scale 98 % → 100 % on open. `Motion.littleArcOpen`.
    static var littleArcOpen: Animation? { Motion.littleArcOpen.curve.swiftUI }
    /// Little Arc content scale to 98 % on close. `Motion.littleArcClose`.
    static var littleArcClose: Animation? { Motion.littleArcClose.curve.swiftUI }
    /// Little Arc content scale to 98 % on "Open in <Space>". `Motion.littleArcExpandToMain`.
    static var littleArcExpandToMain: Animation? { Motion.littleArcExpandToMain.curve.swiftUI }
    /// Peek opening (B49). `Motion.peekOpen` (curve unknown).
    static var peekOpen: Animation? { Motion.peekOpen.curve.swiftUI }
    /// The window command bar fading out on close; opening is not animated. `Motion.commandBarClose`.
    static var commandBarClose: Animation? { Motion.commandBarClose.curve.swiftUI }
    /// The animation for a change of "the command bar is shown": the close fade when it goes
    /// away, none when it appears ([07 §11] observed one-frame open).
    static func commandBarPresence(isPresented: Bool) -> Animation? {
        isPresented ? nil : commandBarClose
    }
    /// The new empty Space's illustration fading away ([06 §1] observed that it goes away; the
    /// ease-out over `NewSpaceIllustrationTrigger.fadeDuration` is inferred). B75.
    static var newSpaceIllustrationFade: Animation { .easeOut(duration: NewSpaceIllustrationTrigger.fadeDuration) }
}

/// The Space pages' slide as a Core Animation spring on each page's layer (B101): the pages are
/// kept as built views (`SidebarSpacePager`) and only their layers move, so no SwiftUI work runs
/// per frame. Same spring as `ShellMotion.spaceSwitch`: `Motion.spaceSwitch`, [07 §11] observed
/// (critically damped, response 0.2 s, the page moves by one sidebar width, no fade).
enum SpacePagerMotion {
    /// Animation key on a page's layer.
    static let key = "openarc.spacePager.slide"

    /// A spring of the layer's horizontal translation from `offset` (points, relative to the
    /// layer's final place) to 0, running until it settles. SwiftUI's spring definition (unit
    /// mass, stiffness (2π / response)², damping 4π · fraction / response).
    static func slide(from offset: CGFloat) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: "transform.translation.x")
        let constants = Motion.spaceSwitch.curve.springConstants ?? (stiffness: 987, damping: 62.8)
        animation.mass = 1
        animation.stiffness = constants.stiffness
        animation.damping = constants.damping
        animation.fromValue = offset
        animation.toValue = 0
        animation.duration = animation.settlingDuration
        return animation
    }
}

/// Which way the Space pager moves: toward a Space later in the dock order, or earlier.
enum SpaceSwitchDirection: Equatable, Sendable {
    case forward
    case backward

    /// The direction from the Space at `old` to the one at `new` in the dock order. A Space not in
    /// the order (new or deleted) counts as forward. inferred.
    static func between(_ old: UUID?, _ new: UUID?, order: [UUID]) -> SpaceSwitchDirection {
        guard let old, let new, let from = order.firstIndex(of: old), let to = order.firstIndex(of: new) else {
            return .forward
        }
        return to < from ? .backward : .forward
    }
}

/// The sidebar's Space pager: the Space shown last and the direction of the latest switch.
/// `SidebarSpacePager` reads the direction when it slides the pages.
@MainActor
final class SpacePagerState {
    private(set) var spaceID: UUID?
    private(set) var direction: SpaceSwitchDirection = .forward
    /// Width of one page. [07 §11] observed: 276 pt, the sidebar width.
    let pageWidth: CGFloat

    init(spaceID: UUID? = nil, pageWidth: CGFloat = CGFloat(Metrics.Sidebar.width)) {
        self.spaceID = spaceID
        self.pageWidth = pageWidth
    }

    /// Records that `newID` is shown; updates the direction when the Space changed.
    func show(_ newID: UUID?, order: [UUID]) {
        guard newID != spaceID else { return }
        if spaceID != nil { direction = SpaceSwitchDirection.between(spaceID, newID, order: order) }
        spaceID = newID
    }

    /// Horizontal offset of a page at the inactive end of its slide: where the incoming page
    /// starts, where the outgoing page ends.
    func offset(for role: SpacePageRole) -> CGFloat {
        switch (role, direction) {
        case (.insertion, .forward), (.removal, .backward): return pageWidth
        case (.insertion, .backward), (.removal, .forward): return -pageWidth
        }
    }
}

/// The incoming (`insertion`) or outgoing (`removal`) page of a Space switch.
enum SpacePageRole: Sendable { case insertion, removal }

// MARK: - Theme bubble

extension ShellMotion {
    /// Theme bubble open. `Motion.themeBubbleOpen`.
    static var themeBubbleOpen: Animation? { Motion.themeBubbleOpen.curve.swiftUI }
    /// Theme bubble close. `Motion.themeBubbleClose`.
    static var themeBubbleClose: Animation? { Motion.themeBubbleClose.curve.swiftUI }
}

/// Open / close motion of a floating bubble panel, run on the panel's root layer. [07 §11]
/// observed (window-list sampler): the theme bubble grows from ≈ 0 × 0 at its anchor to full size
/// with alpha 0 → 1 on one spring (0.31 s / 0.81), and shrinks back with alpha 1 → 0 on a slightly
/// slower, more damped one (0.35 s / 0.85). A layer animation, so the panel keeps its final frame
/// and the SwiftUI content lays out once.
enum FloatingBubbleMotion {
    enum Phase: Sendable { case open, close }

    static func token(_ phase: Phase) -> MotionToken {
        phase == .open ? Motion.themeBubbleOpen : Motion.themeBubbleClose
    }

    /// Scale the bubble grows from and shrinks to. [07 §11] observed ≈ 0 (the window grows from
    /// ≈ 0 × 0, closes at ≈ 1 × 1); a small non-zero value keeps the transform invertible.
    static let collapsedScale: CGFloat = 0.01

    /// Animation keys on the layer.
    static let scaleKey = "openarc.bubble.scale"
    static let opacityKey = "openarc.bubble.opacity"

    /// Point the bubble grows from, in the panel's root view (`size` = the panel, arrow included;
    /// bottom-left origin like an unflipped AppKit view): the arrow tip, which touches the anchor;
    /// without an arrow (Edit Theme… from a menu) the bottom-left corner. [07 §11] observed
    /// "anchored at the bottom left, growing up and right" for Edit Theme…; the arrow tip for
    /// attached bubbles is inferred.
    static func growthOrigin(arrow: FloatingBubbleArrow?, size: CGSize) -> CGPoint {
        guard let arrow else { return .zero }
        switch arrow.edge {
        case .leading: return CGPoint(x: 0, y: size.height - arrow.position)
        case .top: return CGPoint(x: arrow.position, y: size.height)
        }
    }

    /// A scale by `scale` that keeps `point` (in the layer's bounds) in place, for a layer whose
    /// transform applies about `anchorPoint`.
    static func transform(scale: CGFloat, about point: CGPoint, bounds: CGRect, anchorPoint: CGPoint) -> CATransform3D {
        let pivot = CGPoint(x: bounds.minX + anchorPoint.x * bounds.width, y: bounds.minY + anchorPoint.y * bounds.height)
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(dx, dy, 0))
    }

    /// A Core Animation spring with the token's stiffness and damping (SwiftUI's definition, unit
    /// mass), running until it settles.
    static func spring(_ keyPath: String, from: Any, to: Any, phase: Phase) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let constants = token(phase).curve.springConstants ?? (stiffness: 400, damping: 40)
        animation.mass = 1
        animation.stiffness = constants.stiffness
        animation.damping = constants.damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        if phase == .close {
            // Hold the collapsed state until the panel is ordered out.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        return animation
    }

    /// Runs `phase` on `layer`, growing from / shrinking to `origin`. `completion` runs once the
    /// spring has settled (also right away when the user asked to reduce motion).
    @MainActor
    static func run(_ phase: Phase, on layer: CALayer, origin: CGPoint, reduceMotion: Bool,
                    completion: (@MainActor () -> Void)? = nil) {
        cancel(on: layer)
        guard !reduceMotion else {
            completion?()
            return
        }
        let collapsed = NSValue(caTransform3D: transform(scale: collapsedScale, about: origin, bounds: layer.bounds,
                                                         anchorPoint: layer.anchorPoint))
        let identity = NSValue(caTransform3D: CATransform3DIdentity)
        let scale = phase == .open ? spring("transform", from: collapsed, to: identity, phase: phase)
            : spring("transform", from: identity, to: collapsed, phase: phase)
        let fade = phase == .open ? spring("opacity", from: 0, to: 1, phase: phase)
            : spring("opacity", from: 1, to: 0, phase: phase)
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        }
        layer.add(scale, forKey: scaleKey)
        layer.add(fade, forKey: opacityKey)
        CATransaction.commit()
    }

    /// Stops a running open / close and leaves the layer at full size and alpha.
    @MainActor
    static func cancel(on layer: CALayer) {
        layer.removeAnimation(forKey: scaleKey)
        layer.removeAnimation(forKey: opacityKey)
    }
}
