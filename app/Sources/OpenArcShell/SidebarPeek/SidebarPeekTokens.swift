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

    /// A strip outside the window, left of its left edge, that also opens the panel, so the
    /// pointer only has to cross the window's left edge when the window does not touch the screen
    /// edge. inferred (analysis): Arc's window hover tracker keeps an "off the left edge" zone left
    /// of the window, as tall as it, 50 pt wide; once the pointer is in it (or over the traffic
    /// lights) the zone grows to 250 pt, so moving further left does not drop it. B145.
    static let outsideEdgeZoneWidth: CGFloat = 50
    static let outsideEdgeZoneWidthWhileInside: CGFloat = 250

    /// Distance the floating panel travels between its collapsed and open positions: the panel
    /// view's x goes −291 → 0 [07 §11] observed, and the traffic lights inside it sit 291 left of
    /// their open spot while collapsed (close x −274 vs 17) [06 §26.1, §26.2] observed. B54.
    static let collapsedOffset: CGFloat = 291

    /// The travel for a resized sidebar: the panel's width plus the same 15 pt beyond it (291 at
    /// the reference 276), so a wider panel still starts fully out of the window. B144, inferred.
    static func collapsedOffset(sidebarWidth: CGFloat) -> CGFloat {
        collapsedOffset + max(0, sidebarWidth - CGFloat(Metrics.Sidebar.width))
    }

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

    /// Panel fill relative to the pinned sidebar, dark appearance: shaded, then pushed away from
    /// its gray. [06 §26.2] observed (dark, default theme): pinned #2C283E → panel ≈ #1D1B32; these
    /// factors give #1E1A31 (≤ 1.3/255 per channel). inferred (fitted to that one sample). F5-8/17/19.
    static let darkFillShade: Double = 0.67
    static let darkFillSaturationBoost: Double = 1.6
    /// Light appearance: "slightly deeper, more saturated" [06 §14] observed; not sampled, so the
    /// earlier mild factors stay (inferred).
    static let lightFillShade: Double = 0.96
    static let lightFillSaturationBoost: Double = 1.3

    /// The light rim around the panel. [06 §26.2] observed ≈ #5D5F70 (dark, default theme),
    /// width ≈ 2 pt (inferred there). White at 29 % over the dark panel fill gives #5F5C6D on the
    /// default theme (≤ 3/255). inferred rule. F5-18/30.
    static let rimWidth: CGFloat = 2
    static let darkRimWhite: Double = 0.29
    /// Light appearance: a white rim would vanish on a light panel; a faint dark line keeps the
    /// edge. unknown (not captured), our value.
    static let lightRimBlack: Double = 0.08

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
    static func panelFill(for windowBackground: RGBAColor, isDark: Bool) -> RGBAColor {
        let shade = isDark ? darkFillShade : lightFillShade
        let saturation = isDark ? darkFillSaturationBoost : lightFillSaturationBoost
        let c = ThemeDerivation.shade(windowBackground, by: shade)
        let gray = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        func boost(_ v: Double) -> Double { min(max(gray + (v - gray) * saturation, 0), 1) }
        return RGBAColor(red: boost(c.red), green: boost(c.green), blue: boost(c.blue), alpha: windowBackground.alpha)
    }

    /// The panel fill for a palette (its window color and appearance).
    static func panelFill(for palette: ThemePalette) -> RGBAColor {
        panelFill(for: palette.windowBackground, isDark: palette.isDark)
    }

    /// The rim color as a layer over the panel: white in the dark appearance, faint black in light.
    static func rimColor(isDark: Bool) -> RGBAColor {
        isDark ? RGBAColor(hex: 0xFFFFFF, alpha: darkRimWhite) : RGBAColor(hex: 0x000000, alpha: lightRimBlack)
    }

    /// The rim as seen over `fill` (opaque), for checks against the observed color.
    static func rimOver(_ fill: RGBAColor, isDark: Bool) -> RGBAColor {
        let rim = rimColor(isDark: isDark)
        return ThemeDerivation.mix(fill, RGBAColor(red: rim.red, green: rim.green, blue: rim.blue), amount: rim.alpha)
    }
}

/// Pure geometry of the floating panel, in window coordinates (top-left origin).
struct SidebarPeekLayout: Equatable, Sendable {
    var windowSize: CGSize
    /// The window's sidebar width (B144); the panel carries the sidebar at that width.
    var sidebarWidth: CGFloat = CGFloat(Metrics.Sidebar.width)

    /// The rounded panel: 5 pt from the top, bottom and left edges [06 §14] observed. The whole
    /// sidebar moves with it by (5, 5): the traffic lights and the "Lock sidebar" button keep
    /// their pinned positions relative to the panel (close (17, 21), sidebar button x 82)
    /// [06 §26.2] observed, so the panel is the pinned sidebar's width (inferred: its right edge
    /// was not measured). B54.
    var panelFrame: CGRect {
        let inset = SidebarPeekTokens.panelInset
        let width = min(sidebarWidth, max(0, windowSize.width - inset))
        return CGRect(x: inset, y: inset, width: width, height: max(0, windowSize.height - 2 * inset))
    }

    /// Size of the sidebar drawn inside the panel: the panel's own size, laid out from the
    /// panel's top left like the pinned sidebar from the window's. [06 §26.2] observed. B54.
    var sidebarSize: CGSize {
        CGSize(width: sidebarWidth, height: panelFrame.height)
    }

    /// The left-edge hot zone: the strip outside the window left of it (inferred (analysis), B145)
    /// through the window's x = 0 column ([06 §26.2] observed), the window's height. The outside
    /// strip is `outsideEdgeZoneWidthWhileInside` wide while the pointer is already in the zone,
    /// else `outsideEdgeZoneWidth`.
    func edgeZone(isInside: Bool) -> CGRect {
        let outside = isInside ? SidebarPeekTokens.outsideEdgeZoneWidthWhileInside : SidebarPeekTokens.outsideEdgeZoneWidth
        return CGRect(x: -outside, y: 0, width: outside + SidebarPeekTokens.edgeHotZoneWidth, height: windowSize.height)
    }

    /// Where the open panel counts as under the pointer: the panel and the strip left of it, the
    /// window's height (inferred, so the 5 pt margins do not start a collapse). Left of the window
    /// the edge zone keeps it open.
    var keepOpenZone: CGRect {
        CGRect(x: 0, y: 0, width: panelFrame.maxX, height: windowSize.height)
    }

    /// The pointer region of a point in window coordinates (top-left origin); points left of the
    /// window have a negative x. `wasAtEdge`: the previous point was in the edge zone
    /// (`edgeZone(isInside:)`).
    func region(of point: CGPoint, presentation: SidebarPresentation, wasAtEdge: Bool = false) -> SidebarPeekPointerRegion {
        // Exclusive on the right: x = 0 counts, x = 1 does not. [06 §26.2] observed.
        let zone = edgeZone(isInside: wasAtEdge)
        if point.x >= zone.minX, point.x < zone.maxX, point.y >= 0, point.y <= windowSize.height { return .edge }
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
