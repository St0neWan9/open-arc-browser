import SwiftUI
import QuartzCore
import Combine
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
    /// The download badge dropping onto the Library button (B203). `Motion.downloadBadgeDrop`.
    static var downloadBadgeDrop: Animation? { Motion.downloadBadgeDrop.curve.swiftUI }
    /// The dock Space icon's hover fill (B201). `Motion.dockSpaceHover`.
    static var dockSpaceHover: Animation? { Motion.dockSpaceHover.curve.swiftUI }
    /// The recent-files shelf rising in or leaving (B200). `Motion.downloadsShelfOpen` / `downloadsShelfClose`.
    static func downloadsShelf(isShown: Bool) -> Animation? {
        (isShown ? Motion.downloadsShelfOpen : Motion.downloadsShelfClose).curve.swiftUI
    }
    /// The window command bar fading out on close; opening is not animated. `Motion.commandBarClose`.
    static var commandBarClose: Animation? { Motion.commandBarClose.curve.swiftUI }
    /// The animation for a change of "the command bar is shown": the close fade when it goes
    /// away, none when it appears ([07 §11] observed one-frame open).
    static func commandBarPresence(isPresented: Bool) -> Animation? {
        isPresented ? nil : commandBarClose
    }
    /// Folder rows opening (`Motion.folderExpand`) or closing (`Motion.folderCollapse`). B176. None
    /// when the user asked to reduce motion.
    static func folderDisclosure(expanding: Bool, reduceMotion: Bool, pinnedArea: Bool = false) -> Animation? {
        guard !reduceMotion else { return nil }
        if pinnedArea, !expanding { return Motion.pinnedCollapse.curve.swiftUI }
        return (expanding ? Motion.folderExpand : Motion.folderCollapse).curve.swiftUI
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
    /// Width of one page. [07 §11] observed: 276 pt, the sidebar width; the window's sidebar width
    /// once resized (B144: `SidebarSpacePagerView` passes it to `offset(for:width:)`).
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
    func offset(for role: SpacePageRole, width: CGFloat? = nil) -> CGFloat {
        let distance = width ?? pageWidth
        switch (role, direction) {
        case (.insertion, .forward), (.removal, .backward): return distance
        case (.insertion, .backward), (.removal, .forward): return -distance
        }
    }
}

/// The incoming (`insertion`) or outgoing (`removal`) page of a Space switch.
enum SpacePageRole: Sendable { case insertion, removal }

/// A two-finger swipe between Spaces that the pages follow (B184, issue #1), and the window color
/// that moves with the pages of any Space switch (issue #15, B195). The view model feeds it;
/// `SidebarSpacePagerView` moves the pages from `events` and `SpaceBlendPaintView` repaints the
/// background from `blendChanges`, both without SwiftUI work per frame; the list's scroll knob
/// hides while `isActive`.
@MainActor
final class SpaceSwipeState: ObservableObject {
    enum Event: Equatable {
        case began(previous: UUID?, next: UUID?)
        /// Content travel in points since the swipe began (negative: toward the next Space).
        case moved(CGFloat)
        /// The swipe ended: `target` is the Space it moves to, nil to spring back.
        case ended(target: UUID?)
    }

    /// Published only when a swipe starts or ends, so observers do no work per frame.
    @Published private(set) var isActive = false
    private(set) var previous: UUID?
    private(set) var next: UUID?
    /// Width of one page: the window's sidebar width, set by the pager. [07 §11] observed default.
    var pageWidth: CGFloat = CGFloat(Metrics.Sidebar.width)
    let events = PassthroughSubject<Event, Never>()
    /// What was sent, for tests.
    private(set) var lastEvent: Event?

    // MARK: Window color blend (issue #15, B195)
    //
    // None of this is published: SwiftUI views that observed the per-frame blend made the swipe
    // stutter (B195). Only the background's layer follows it, through `blendChanges`.

    /// The Space whose colors the window background moves to while the pages slide; nil when the
    /// background shows the selected Space as it is.
    private(set) var blendTargetSpaceID: UUID?
    /// How far the pages have moved toward `blendTargetSpaceID`, in points (0 to `pageWidth`).
    private(set) var blendTravel: CGFloat = 0
    /// `blendTravel` when the blend began: a slide that started part of the way across blends over
    /// the rest of the way.
    private var blendStartTravel: CGFloat = 0
    /// Bumped whenever a blend starts from the colors on screen; the background takes the colors it
    /// shows at that moment as the blend's start.
    private(set) var blendGeneration = 0
    /// Where the running settle takes `blendTravel`, nil when none runs.
    private(set) var settleTravel: CGFloat?
    /// Bumped by every settle and every swipe, so the frames of an overtaken settle stop.
    private var settleToken = 0
    /// The running settle: its token and the travel it goes from and to. The background animates
    /// it on the render server, in step with the pages' own spring (B208), so a busy main thread
    /// does not hold the color back.
    private(set) var settleRun: (id: Int, from: CGFloat, to: CGFloat)?
    /// A Dock or shortcut switch: the color follows the page's position linearly, as Arc does
    /// ([06 §39] B208, observed: 50 % at half way, on the Space-switch spring). A swipe keeps the
    /// user's rule, the target's colors by the midline (`SpaceBlend.progress`).
    private(set) var blendFollowsPage = false
    /// Sent whenever the blend changes: per move, per display frame while it settles.
    let blendChanges = PassthroughSubject<Void, Never>()
    /// Calls `tick` once per display frame with the seconds since the settle began, until it
    /// returns false. Tests replace it.
    var frameDriver: (_ tick: @escaping @MainActor (Double) -> Bool) -> Void = { DisplayFrames.run($0) }

    /// How far the background is from the start colors (0) to the target's (1).
    var blendProgress: Double { blendProgress(atTravel: blendTravel) }

    /// The blend at `travel` points across, for the running blend's start and curve.
    func blendProgress(atTravel travel: CGFloat) -> Double {
        if blendFollowsPage {
            let span = pageWidth - blendStartTravel
            guard span > 0 else { return 1 }
            return Double(min(max((travel - blendStartTravel) / span, 0), 1))
        }
        return SpaceBlend.progress(travel: travel, start: blendStartTravel, width: pageWidth)
    }

    func begin(previous: UUID?, next: UUID?) {
        self.previous = previous
        self.next = next
        stopSettle()
        blendFollowsPage = false
        // A blend still settling lands at once, like the pages (`SidebarSpacePagerView`).
        blendGeneration &+= 1
        setBlend(target: nil, travel: 0, start: 0)
        isActive = true
        send(.began(previous: previous, next: next))
    }

    func move(_ offset: CGFloat) {
        guard isActive else { return }
        let direction = offset < 0 ? next : previous
        // No Space that way: nothing to blend to.
        setBlend(target: direction, travel: direction == nil ? 0 : min(abs(offset), pageWidth), start: 0)
        send(.moved(offset))
    }

    /// The fingers lifted. The blend settles with the pages, on their spring: on to the target
    /// Space's colors when the swipe commits (`target`), back to the current Space's when it springs
    /// back (nil).
    func end(target: UUID?) {
        guard isActive else { return }
        isActive = false
        send(.ended(target: target))
        guard blendTargetSpaceID != nil else { return }
        settle(to: target == nil ? 0 : pageWidth)
    }

    /// The selection is about to move to `spaceID` and its page slides in (a Dock click, a
    /// shortcut, a committed swipe): the background blends from the colors on screen to
    /// `spaceID`'s with the page, on its spring. `travel` is how far the page already is across
    /// (a switch that overtakes a running slide). A committed swipe is already settling there.
    func slide(to spaceID: UUID?, travel: CGFloat) {
        guard !isActive else { return }
        if spaceID != nil, blendTargetSpaceID == spaceID, settleTravel == pageWidth { return }
        stopSettle()
        blendGeneration &+= 1
        guard let spaceID else {
            setBlend(target: nil, travel: 0, start: 0)
            return
        }
        let start = min(max(travel, 0), pageWidth)
        blendFollowsPage = true
        setBlend(target: spaceID, travel: start, start: start)
        settle(to: pageWidth)
    }

    private func settle(to end: CGFloat) {
        settleToken &+= 1
        let token = settleToken, from = blendTravel
        settleTravel = end
        settleRun = (token, from, end)
        blendChanges.send()
        frameDriver { [weak self] elapsed in
            guard let self, self.settleToken == token else { return false }
            let fraction = SpaceBlend.springFraction(elapsed: elapsed)
            guard fraction < 1 else {
                // Settled: the background shows the selected Space as it is again.
                self.settleTravel = nil
                self.settleRun = nil
                self.setBlend(target: nil, travel: 0, start: 0)
                return false
            }
            self.setBlend(target: self.blendTargetSpaceID, travel: from + (end - from) * fraction,
                          start: self.blendStartTravel)
            return true
        }
    }

    private func stopSettle() {
        settleToken &+= 1
        settleTravel = nil
        settleRun = nil
    }

    private func setBlend(target: UUID?, travel: CGFloat, start: CGFloat) {
        guard target != blendTargetSpaceID || travel != blendTravel || start != blendStartTravel else { return }
        blendTargetSpaceID = target
        blendTravel = target == nil ? 0 : travel
        blendStartTravel = target == nil ? 0 : start
        blendChanges.send()
    }

    private func send(_ event: Event) {
        lastEvent = event
        events.send(event)
    }
}

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
