import CoreGraphics
import Foundation
import OpenArcDesign

/// Pure frame computation for the main window (top-left origin, points). Views read frames from
/// here so layout can be unit-tested against the measured tokens without rendering.
public struct MainWindowLayout: Equatable, Sendable {
    public var windowSize: CGSize
    public var isSidebarVisible: Bool
    /// View ▸ Show Toolbar: the address and navigation buttons move from the sidebar into a strip at
    /// the top of the web panel. [06 §17] observed.
    public var isWebToolbarShown: Bool

    /// While Peek is open the page behind shrinks by this much on every side. [06 §22.2] observed
    /// (B49, `PeekMetrics.backgroundInset`); 0 otherwise.
    public var peekBackgroundInset: Double = 0

    public init(windowSize: CGSize, isSidebarVisible: Bool = true, isWebToolbarShown: Bool = false) {
        self.windowSize = windowSize
        self.isSidebarVisible = isSidebarVisible
        self.isWebToolbarShown = isWebToolbarShown
    }

    /// The toolbar strip: the top 32 pt of the web panel, inside its rounded corners. Empty while
    /// the toolbar is off. [06 §17.2] observed (276, 10, 1634 × 32; hidden sidebar 10, 10, 1900 × 32).
    public var webToolbarFrame: CGRect {
        guard isWebToolbarShown else { return .zero }
        let panel = webPanelFrame
        return CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: min(Metrics.WebToolbar.height, panel.height))
    }

    /// Where the page goes: the web panel below the toolbar strip (the whole panel while the
    /// toolbar is off). [06 §17.2] observed (page from y 42, 933 tall in a 985 window).
    public var pageFrame: CGRect {
        let panel = webPanelFrame
        let strip = webToolbarFrame.height
        return CGRect(x: panel.minX, y: panel.minY + strip, width: panel.width, height: max(0, panel.height - strip))
    }

    /// The window-drag strip at the top of the page area ("Allow window dragging from the top of
    /// webpages", B84). [06 §13] observed: a short bar centered at the top of the page area. Its
    /// size is not recorded; ours (inferred): a 120 × 12 pt grab area at the page's top edge,
    /// drawing a 36 × 4 pt handle. Empty when the setting is off or the page area is too small.
    public func windowDragStripFrame(isEnabled: Bool) -> CGRect {
        guard isEnabled else { return .zero }
        let page = pageFrame
        let width = min(Self.dragStripSize.width, page.width)
        guard width > 0, page.height >= Self.dragStripSize.height else { return .zero }
        return CGRect(x: page.midX - width / 2, y: page.minY, width: width, height: Self.dragStripSize.height)
    }

    /// Grab area of the drag strip. inferred.
    public static let dragStripSize = CGSize(width: 120, height: 12)
    /// The visible handle inside the grab area. inferred.
    public static let dragHandleSize = CGSize(width: 36, height: 4)

    /// Whether the strip draws its handle. [06 §13] E27 observed (2026-10-30): no handle on the
    /// empty panel (no tab selected) or on `about:blank`; the B84 rule that always showed it there
    /// is dropped. On a loaded page it shows while the pointer is over the grab area (B84,
    /// inferred; when Arc shows it is still unknown). The grab area itself stays everywhere.
    public static func showsDragHandle(isBlankPage: Bool, isHovered: Bool) -> Bool {
        !isBlankPage && isHovered
    }

    /// The page area shows no page: no tab selected, no address yet, or `about:blank`. [06 §13].
    public static func isBlankPage(hasSelectedTab: Bool, url: URL?) -> Bool {
        guard hasSelectedTab, let url else { return true }
        return url.absoluteString == "about:blank"
    }

    /// How far the sidebar content below the (removed) URL box moves up while the toolbar shows.
    /// [06 §17.1] observed (46: favorites y 82 → 36).
    public var sidebarContentShift: Double {
        isWebToolbarShown ? Metrics.WebToolbar.sidebarContentShift : 0
    }

    /// Sidebar area (includes its right-hand gap). [07 §1] observed
    public var sidebarFrame: CGRect {
        guard isSidebarVisible else { return .zero }
        return CGRect(x: 0, y: 0, width: min(Metrics.Sidebar.width, windowSize.width), height: windowSize.height)
    }

    /// Web panel: 10 pt from the top, right and bottom edges, flush with the sidebar on the left.
    /// [07 §1] observed (276, 10, 1634 × 965 in a 1920 × 985 window).
    /// With the sidebar hidden, a ≈ 5 pt themed border on all four sides. [06 §14] observed.
    public var webPanelFrame: CGRect {
        guard peekBackgroundInset > 0 else { return baseWebPanelFrame }
        return baseWebPanelFrame.insetBy(dx: peekBackgroundInset, dy: peekBackgroundInset)
    }

    /// The web panel without the Peek inset.
    public var baseWebPanelFrame: CGRect {
        guard isSidebarVisible else {
            let inset = SidebarPeekTokens.hiddenWebPanelInset
            return CGRect(x: inset, y: inset, width: max(0, windowSize.width - 2 * inset), height: max(0, windowSize.height - 2 * inset))
        }
        let leading = sidebarFrame.maxX + Metrics.WebPanel.insetLeading
        let width = windowSize.width - leading - Metrics.WebPanel.insetTrailing
        let height = windowSize.height - Metrics.WebPanel.insetTop - Metrics.WebPanel.insetBottom
        return CGRect(x: leading, y: Metrics.WebPanel.insetTop, width: max(0, width), height: max(0, height))
    }

    /// Address/search field inside the sidebar: x 8–268, y 46–82. [07 §4] observed. While the
    /// toolbar shows, the sidebar has no address field ([06 §17.1] observed); the frame stays for
    /// callers that only need the toolbar-off geometry.
    public var addressFieldFrame: CGRect {
        let inset = Metrics.Sidebar.addressFieldHorizontalInset
        return CGRect(
            x: inset,
            y: Metrics.Sidebar.addressFieldTop,
            width: sidebarContentWidth - 2 * inset,
            height: Metrics.Sidebar.addressFieldHeight
        )
    }

    /// Favorites blocks: x 8–268, y 90–137 [07 §4] observed; 46 pt higher while the toolbar shows
    /// [06 §17.1] observed.
    public var favoritesFrame: CGRect {
        let inset = Metrics.Sidebar.addressFieldHorizontalInset
        return CGRect(
            x: inset,
            y: Metrics.Sidebar.favoritesTop - sidebarContentShift,
            width: sidebarContentWidth - 2 * inset,
            height: Metrics.Sidebar.favoritesHeight
        )
    }

    /// Command bar panel: horizontally centered; the top stays where the five-result panel puts it
    /// (5 pt above the window's vertical center, y 324 in a 985 pt window) and the panel grows or
    /// shrinks downward with the results. [07 §5] observed position; top alignment inferred.
    public func commandBarFrame(resultCount: Int = 5) -> CGRect {
        let c = Metrics.CommandBar.self
        let rows = max(0, resultCount)
        let height = rows == 0
            ? c.inputRowHeight
            : c.inputRowHeight + c.resultsTopGap + Double(rows) * c.resultRowPitch + c.bottomPadding
        let width = min(c.width, windowSize.width)
        let x = (windowSize.width - width) / 2
        return CGRect(x: x, y: Self.commandBarTop(containerHeight: windowSize.height), width: width, height: height)
    }

    /// Top edge of the window command bar in a container of this height. [07 §5] observed (324 in 985).
    public static func commandBarTop(containerHeight: Double) -> Double {
        let c = Metrics.CommandBar.self
        return max(0, (containerHeight - c.heightWithFiveResults) / 2 - c.centerOffsetAboveMiddle)
    }

    /// Width of the sidebar content area: the whole sidebar; the URL box, favorites and selected
    /// rows are inset 8 on both sides (x 8–268 of 276). [07 §1] observed.
    var sidebarContentWidth: Double {
        Metrics.Sidebar.width
    }
}
