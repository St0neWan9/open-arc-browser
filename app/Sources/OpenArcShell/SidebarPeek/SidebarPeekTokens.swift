import SwiftUI
import OpenArcModel
import OpenArcDesign

// Local tokens of the hidden-sidebar peek (B34). Source: docs/arc-spec/06-flows.md §14, captured
// with real mouse events. Timing comes from `OpenArcDesign.Motion` ([07 §11], E7). Values the
// spec does not pin down are labeled unknown / inferred.

enum SidebarPeekTokens {
    /// Width of the invisible hot zone along the window's left edge: only the first column of
    /// points (x = 0). [06 §26.2] observed with a real pointer: x = 0 opens, x = 1–5 never does
    /// (6 runs); supersedes the earlier "x ≈ 0–2" reading of [06 §14]. B54.
    static let edgeHotZoneWidth: CGFloat = 1

    /// Distance the floating panel travels between its collapsed and open positions: the panel
    /// view's x goes −291 → 0 [07 §11] observed, and the traffic lights inside it sit 291 left of
    /// their open spot while collapsed (close x −274 vs 17) [06 §26.1, §26.2] observed. B54.
    static let collapsedOffset: CGFloat = 291

    /// Inset of the floating panel from the window's top, bottom and left edges.
    /// [06 §14] observed (≈ 5 pt).
    static let panelInset: CGFloat = 5

    /// Themed border around the web panel while the sidebar is hidden, on all four sides: the
    /// same inset the panel keeps from the top, right and bottom edges with the sidebar shown, so
    /// hiding the sidebar only moves the left edge. [06 §14] observed 2026-10-25 from Arc
    /// screenshots (hidden and shown both ≈ 9 pt at top/right/bottom, hidden left ≈ 8.5 pt); the
    /// earlier "≈ 5 pt" reading was wrong. Tied to `Metrics.WebPanel.insetTrailing` so the
    /// border is uniform.
    static let hiddenWebPanelInset: Double = Metrics.WebPanel.insetTrailing

    /// Corner radius of the floating panel. [06 §14] observed "rounded"; the value is unknown.
    static let panelCornerRadius: CGFloat = 10

    /// Drop shadow of the floating panel. [06 §14] observed "drop shadow"; the values are unknown.
    static let shadowOpacity: Double = 0.22
    static let shadowRadius: CGFloat = 12
    static let shadowOffsetX: CGFloat = 2
    static let shadowOffsetY: CGFloat = 2

    /// Panel fill relative to the pinned sidebar: "slightly deeper, more saturated".
    /// [06 §14] observed; the factors are inferred.
    static let fillShade: Double = 0.96
    static let fillSaturationBoost: Double = 1.3

    /// Time the pointer rests at the edge before the panel slides out. `Motion.sidebarPeekOpenDwell`:
    /// [07 §11] observed ≈ 0.11 s (≤ 100 ms never opens, ≥ 115 ms always does).
    static var openDelay: TimeInterval { Motion.sidebarPeekOpenDwell }

    /// Time after the pointer left the panel before it collapses. `Motion.sidebarPeekCloseDelay`:
    /// [07 §11] observed none (back at the collapsed position within one frame).
    static var closeDelay: TimeInterval { Motion.sidebarPeekCloseDelay }

    /// Slide in / out of the floating panel: `ShellMotion.sidebarPeekSlide` ([07 §11] unknown curve,
    /// ≤ `Motion.sidebarPeekSlideMax`).
    static var slideDuration: Double { Motion.sidebarPeekSlide.curve.nominalDuration }

    /// The panel fill for a pinned-sidebar color: shaded and pushed away from its gray.
    static func panelFill(for windowBackground: RGBAColor) -> RGBAColor {
        let c = ThemeDerivation.shade(windowBackground, by: fillShade)
        let gray = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        func boost(_ v: Double) -> Double { min(max(gray + (v - gray) * fillSaturationBoost, 0), 1) }
        return RGBAColor(red: boost(c.red), green: boost(c.green), blue: boost(c.blue), alpha: windowBackground.alpha)
    }
}

/// Pure geometry of the floating panel, in window coordinates (top-left origin).
struct SidebarPeekLayout: Equatable, Sendable {
    var windowSize: CGSize

    /// The rounded panel: 5 pt from the top, bottom and left edges [06 §14] observed. The whole
    /// sidebar moves with it by (5, 5): the traffic lights and the "Lock sidebar" button keep
    /// their pinned positions relative to the panel (close (17, 21), sidebar button x 82)
    /// [06 §26.2] observed, so the panel is the pinned sidebar's width (inferred: its right edge
    /// was not measured). B54.
    var panelFrame: CGRect {
        let inset = SidebarPeekTokens.panelInset
        let width = min(CGFloat(Metrics.Sidebar.width), max(0, windowSize.width - inset))
        return CGRect(x: inset, y: inset, width: width, height: max(0, windowSize.height - 2 * inset))
    }

    /// Size of the sidebar drawn inside the panel: the panel's own size, laid out from the
    /// panel's top left like the pinned sidebar from the window's. [06 §26.2] observed. B54.
    var sidebarSize: CGSize {
        CGSize(width: CGFloat(Metrics.Sidebar.width), height: panelFrame.height)
    }

    /// The left-edge hot zone: the x = 0 column. [06 §26.2] observed.
    var edgeZone: CGRect {
        CGRect(x: 0, y: 0, width: SidebarPeekTokens.edgeHotZoneWidth, height: windowSize.height)
    }

    /// Where the open panel counts as under the pointer: the panel and the strip left of it, the
    /// full window height (inferred, so the 5 pt margins do not start a collapse).
    var keepOpenZone: CGRect {
        CGRect(x: 0, y: 0, width: panelFrame.maxX, height: windowSize.height)
    }

    /// The pointer region of a point in window coordinates (top-left origin).
    func region(of point: CGPoint, presentation: SidebarPresentation) -> SidebarPeekPointerRegion {
        // Exclusive on the right: x = 0 counts, x = 1 does not. [06 §26.2] observed.
        if point.x >= edgeZone.minX, point.x < edgeZone.maxX, point.y >= 0, point.y <= windowSize.height { return .edge }
        if presentation == .peeking, keepOpenZone.contains(point) { return .overlay }
        return .outside
    }
}

// MARK: - Environment

private struct SidebarPresentationKey: EnvironmentKey {
    static let defaultValue: SidebarPresentation = .pinned
}

private struct SidebarFillOverrideKey: EnvironmentKey {
    static let defaultValue: RGBAColor? = nil
}

extension EnvironmentValues {
    /// How the sidebar in this subtree is shown: the top bar's sidebar button reads it for its
    /// "Hide sidebar" / "Lock sidebar" label. [06 §14] observed.
    var sidebarPresentation: SidebarPresentation {
        get { self[SidebarPresentationKey.self] }
        set { self[SidebarPresentationKey.self] = newValue }
    }

    /// Background of the sidebar instead of the window color (the floating panel's deeper fill).
    var sidebarFillOverride: RGBAColor? {
        get { self[SidebarFillOverrideKey.self] }
        set { self[SidebarFillOverrideKey.self] = newValue }
    }
}
