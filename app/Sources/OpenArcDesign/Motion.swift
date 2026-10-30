import Foundation

// Motion tokens: delays, durations and animation curves of every animated surface.
//
// Source: docs/arc-spec/07-design-system.md §11 动效(E7) and design-tokens.json `motion`, measured
// on the live app with an AX frame sampler and a window-list sampler (60 Hz commit frames, fitted
// by least squares). Short form in comments: [07 §11]. Values that are fits of measured frames
// carry `observed` when the spec labels the animation observed, `inferred` when only the curve is
// a guess from few samples, and `unknown` for placeholders (layer-only animations the samplers
// cannot see). No UI framework here: the shell maps `MotionCurve` to SwiftUI / Core Animation.

/// Evidence level of a motion token (see CLAUDE.md).
public enum MotionEvidence: String, Sendable, CaseIterable {
    case observed
    case inferred
    case unknown
}

/// An animation curve, independent of the UI framework.
public enum MotionCurve: Equatable, Sendable {
    /// No animation: the change lands in one frame. [07 §11] "AX 跳变".
    case instant
    /// SwiftUI-style spring: `response` in seconds, `dampingFraction` 1 = critically damped.
    case spring(response: Double, dampingFraction: Double)
    /// CSS-style cubic Bézier through (0,0), (x1,y1), (x2,y2), (1,1) over `duration` seconds.
    case timingCurve(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double)
    case easeOut(duration: Double)
    case easeInOut(duration: Double)

    /// Equivalent stiffness / damping of a spring for unit mass (SwiftUI's definition):
    /// k = (2π / response)², c = 4π · dampingFraction / response. nil for other curves.
    public var springConstants: (stiffness: Double, damping: Double)? {
        guard case let .spring(response, fraction) = self, response > 0 else { return nil }
        let omega = 2 * Double.pi / response
        return (omega * omega, 2 * fraction * omega)
    }

    /// Nominal length in seconds: the duration of timed curves, the response of a spring
    /// (≈ when it gets close to rest), 0 for `instant`.
    public var nominalDuration: Double {
        switch self {
        case .instant: return 0
        case .spring(let response, _): return response
        case .timingCurve(_, _, _, _, let duration), .easeOut(let duration), .easeInOut(let duration): return duration
        }
    }
}

/// A curve with its evidence level.
public struct MotionToken: Equatable, Sendable {
    public let curve: MotionCurve
    public let evidence: MotionEvidence

    public init(_ curve: MotionCurve, _ evidence: MotionEvidence) {
        self.curve = curve
        self.evidence = evidence
    }
}

public enum Motion {
    // MARK: Sidebar

    /// Space switch: the Space page (name row + tab list) pages sideways by one sidebar width, no
    /// fade. [07 §11] observed: critically damped spring, response 0.200 s, dampingFraction 1.00
    /// (stiffness ≈ 987, damping ≈ 63), 10 runs × 15–17 frames, rms 0.16 pt; values fitted.
    public static let spaceSwitch = MotionToken(.spring(response: 0.2, dampingFraction: 1.0), .observed)

    /// Sidebar cross-fade when the Create Space view goes away. [06 §1] observed (≈ 0.3 s); the
    /// curve is unknown. Used only for Space creation, not for switching (B40).
    public static let spaceCreateFade = MotionToken(.easeInOut(duration: 0.3), .observed)

    /// Sidebar hide/show (⌘S): the web content width settles in 4 frames (≈ 67 ms) with a strong
    /// ease-out, frames at progress 0.632 / 0.838 / 0.951 / 1.0. [07 §11] observed frames; the
    /// curve cubic-bezier(0.03, 0.62, 0.54, 0.95) over ≈ 65 ms is inferred. The sidebar slide
    /// itself is a layer animation (unknown), so it uses the same curve.
    public static let sidebarToggle = MotionToken(
        .timingCurve(x1: 0.03, y1: 0.62, x2: 0.54, y2: 0.95, duration: 0.067), .inferred
    )

    /// Hidden-sidebar peek: time the pointer must rest at the left edge before the panel comes
    /// out. [07 §11] observed: dwell ≤ 100 ms never opens, ≥ 115 ms always does (≈ 105–115 ms).
    public static let sidebarPeekOpenDwell: Double = 0.11

    /// Peek: delay between the pointer leaving the panel and the collapse. [07 §11] observed:
    /// none (the panel is back at its collapsed position within one frame).
    public static let sidebarPeekCloseDelay: Double = 0

    /// Peek: upper bound of the slide out/in. [07 §11] observed: the panel view leaves the AX tree
    /// ≈ 300 ms after the collapse starts.
    public static let sidebarPeekSlideMax: Double = 0.3

    /// Peek slide in/out. [07 §11]: layer animation, curve and duration unknown; kept at our
    /// 0.15 s ease-out, inside the 0.3 s bound.
    public static let sidebarPeekSlide = MotionToken(.easeOut(duration: 0.15), .unknown)

    /// Favorites making room for a dragged tab. [06 §15.5] observed (an intermediate frame was
    /// seen when leaving); duration and curve unknown.
    public static let favoriteMakeRoom = MotionToken(.easeInOut(duration: 0.15), .unknown)

    /// Hover delay before a tab hover card appears. [06 §12] observed (≈ 0.5 s); not seen again
    /// in E7 within 1.7 s of real hover ([07 §11] unknown), so the value stays.
    public static let hoverCardDelay: Double = 0.5

    /// Hover card appear/disappear. [07 §11] unknown (the card never showed in the samplers);
    /// no frame animation.
    public static let hoverCard = MotionToken(.instant, .unknown)

    /// The sidebar list's thin scroller fading in / out as the pointer enters / leaves the
    /// sidebar. [04 §sidebar] observed "visible on hover"; the fade is unknown (B89).
    public static let sidebarScrollerFade = MotionToken(.easeInOut(duration: 0.2), .unknown)

    /// Selection highlight moving between rows. [07 §11] unknown (layer-drawn); no animation.
    public static let selectionHighlight = MotionToken(.instant, .unknown)

    // MARK: Layout changes Arc does not animate

    /// Command bar open/close, tab row insert/remove (new tab, ⌘W), folder disclosure, split view
    /// add/close: [07 §11] observed one-frame changes in AX, so no frame (layout) animation. Any
    /// fade or scale on layers is unknown.
    public static let layoutChange = MotionToken(.instant, .observed)

    /// Library enter/exit: [07 §11] observed one-frame frame change; the old view leaves after
    /// ≈ 0.5 s, so a cross-fade of at most that long may run on layers (curve unknown). Ours swaps
    /// in one frame.
    public static let library = MotionToken(.instant, .observed)
    public static let libraryCrossfadeMax: Double = 0.5

    // MARK: Floating windows

    /// Theme bubble open: the bubble grows from its anchor (bottom left) with alpha 0 → 1 on the
    /// same curve. [07 §11] observed: spring response ≈ 0.31 s, dampingFraction ≈ 0.81 (3 runs),
    /// overshoot ≈ 1.5 %; values fitted.
    public static let themeBubbleOpen = MotionToken(.spring(response: 0.31, dampingFraction: 0.81), .observed)

    /// Theme bubble close: shrinks back to the anchor with alpha 1 → 0. [07 §11] observed: spring
    /// response ≈ 0.35 s, dampingFraction ≈ 0.85 (3 runs); values fitted.
    public static let themeBubbleClose = MotionToken(.spring(response: 0.35, dampingFraction: 0.85), .observed)

    /// Little Arc open: no fade; the window grows from 98 % to 100 % in ≈ 80 ms with ≈ 1 pt
    /// overshoot, at rest after ≈ 130 ms. [07 §11] observed timing; the spring is inferred
    /// (only 10 pt of travel).
    public static let littleArcOpen = MotionToken(.spring(response: 0.24, dampingFraction: 0.45), .inferred)

    /// Little Arc close (Escape): alpha 1 → 0 while it shrinks to ≈ 98 %. [07 §11] observed:
    /// cubic-bezier(0.27, 1.0, 0.40, 0.98) over ≈ 200 ms (or spring 0.14 s / 1.0); values fitted.
    public static let littleArcClose = MotionToken(
        .timingCurve(x1: 0.27, y1: 1.0, x2: 0.40, y2: 0.98, duration: 0.2), .observed
    )

    /// Little Arc "Open in <Space>": the window fades out and shrinks ≈ 2 %; the main window has
    /// no size animation. [07 §11] observed: cubic-bezier(0.33, 0.71, 0.19, 1.0) over ≈ 190 ms
    /// (or spring 0.16 s / 0.94), 1 run; values fitted.
    public static let littleArcExpandToMain = MotionToken(
        .timingCurve(x1: 0.33, y1: 0.71, x2: 0.19, y2: 1.0, duration: 0.19), .observed
    )

    /// Scale a Little Arc window starts from when it opens and ends at when it closes. [07 §11]
    /// observed (480×323 ↔ 490×329, ≈ 98 %).
    public static let littleArcScale: Double = 0.98

    /// Little Arc growing after its first page load: the window frame is set to the final size in
    /// one frame. [07 §11] observed.
    public static let littleArcGrowOnLoad = MotionToken(.instant, .observed)

    /// Command bar close (Esc, click outside, a pick): [07 §11] observed that on the first frame
    /// the panel's children collapse to its lower left and the panel is gone ≈ 40–60 ms later
    /// (≈ 3 frames; design-tokens.json `motion.commandBar.closeMs` 50). What the pixels do in
    /// those frames is unknown (layer), so ours is a fade-out over the observed ≈ 50 ms: duration
    /// observed, curve inferred. Opening stays a one-frame jump (`layoutChange`).
    public static let commandBarClose = MotionToken(.easeOut(duration: 0.05), .inferred)
}
