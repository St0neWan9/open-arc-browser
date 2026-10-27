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
    /// The new empty Space's illustration fading away ([06 §1] observed that it goes away; the
    /// ease-out over `NewSpaceIllustrationTrigger.fadeDuration` is inferred). B75.
    static var newSpaceIllustrationFade: Animation { .easeOut(duration: NewSpaceIllustrationTrigger.fadeDuration) }

    /// Transition of the Space page: the new page comes in from the side it lies on in the dock
    /// order and pushes the old one out the other side, by one page width, with no fade.
    /// [07 §11] observed: the page container's x moves by one sidebar width (276 pt).
    /// The direction is read from `pager` when the transition runs, not when the old page was
    /// last drawn: SwiftUI keeps a removed view's modifiers as they were, so a direction stored
    /// by value would send the outgoing page the wrong way after a reversal.
    @MainActor
    static func spacePageTransition(_ pager: SpacePagerState) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SpacePageOffset(pager: pager, role: .insertion, isActive: true),
                                 identity: SpacePageOffset(pager: pager, role: .insertion, isActive: false)),
            removal: .modifier(active: SpacePageOffset(pager: pager, role: .removal, isActive: true),
                               identity: SpacePageOffset(pager: pager, role: .removal, isActive: false))
        )
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
/// A reference, so page transitions read the current direction (see `spacePageTransition`).
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

    /// Horizontal offset of a page at the inactive end of its transition.
    func offset(for role: SpacePageOffset.Role) -> CGFloat {
        switch (role, direction) {
        case (.insertion, .forward), (.removal, .backward): return pageWidth
        case (.insertion, .backward), (.removal, .forward): return -pageWidth
        }
    }
}

/// Moves a Space page sideways by one page while it is inserted or removed.
struct SpacePageOffset: ViewModifier {
    enum Role: Sendable { case insertion, removal }
    let pager: SpacePagerState
    let role: Role
    let isActive: Bool

    func body(content: Content) -> some View {
        content.offset(x: isActive ? pager.offset(for: role) : 0)
    }
}

// MARK: - Theme bubble

/// The theme bubble grows from its anchor with alpha 0 → 1 on one spring. [07 §11] observed:
/// spring 0.31 s / 0.81 from ≈ 0 size at the anchor. Applied to the bubble's content; the
/// container is still the system popover (plan B42), whose own close fade stays the system's
/// until a custom panel can run `Motion.themeBubbleClose`.
struct ThemeBubbleMotion: ViewModifier {
    /// Point the bubble grows from: the corner or edge next to its anchor.
    let anchor: UnitPoint
    @State private var isShown = false

    /// Scale the bubble starts from. [07 §11] observed ≈ 0 (the window grows from ≈ 0 × 0); a
    /// small non-zero value keeps the layout valid.
    static let initialScale: CGFloat = 0.01

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown ? 1 : Self.initialScale, anchor: anchor)
            .opacity(isShown ? 1 : 0)
            .onAppear { withAnimation(ShellMotion.themeBubbleOpen) { isShown = true } }
    }
}

extension ShellMotion {
    /// Theme bubble open. `Motion.themeBubbleOpen`.
    static var themeBubbleOpen: Animation? { Motion.themeBubbleOpen.curve.swiftUI }
    /// Theme bubble close. `Motion.themeBubbleClose` (needs a custom panel, see `ThemeBubbleMotion`).
    static var themeBubbleClose: Animation? { Motion.themeBubbleClose.curve.swiftUI }
}

extension View {
    /// Grows the view from `anchor` like Arc's theme bubble. [07 §11] observed.
    func themeBubbleMotion(anchor: UnitPoint) -> some View {
        modifier(ThemeBubbleMotion(anchor: anchor))
    }
}
