import CoreGraphics
import Foundation
import OpenArcModel
import OpenArcDesign

// The slim top bar of each split pane and the page area below it (B18).
//
// Spec sources (docs/arc-spec/):
//   [06 §5]  observed: every pane has its own top bar with back, forward, a centered "🔗 domain"
//            pill and a close ✕ at the top right; the top bar of an inactive pane is fainter.
//            Sizes and the dimming amount were not measured, so they are local tokens below.
//   [06 §17.6] observed: the pane bar is the web toolbar strip (B43). The bar's buttons and domain
//            group are drawn by `WebToolbarView` with `WebToolbarLayout`; this file keeps the
//            bar / page split, the bar state and the pane actions.

/// Local tokens of the pane top bar. None of these were measured.
public enum SplitPaneBarTokens {
    /// Height of the bar above the page. [06 §5] unknown ("slim").
    public static let height: Double = 32
    /// Side of the back, forward and close buttons. unknown.
    public static let buttonSize: Double = 24
    /// Space between the pane edge and the outer buttons. unknown.
    public static let horizontalPadding: Double = 4
    /// Space between the back and forward buttons. unknown.
    public static let buttonSpacing: Double = 2
    /// Height of the domain pill. unknown.
    public static let pillHeight: Double = 22
    /// Widest the domain pill gets. unknown.
    public static let pillMaxWidth: Double = 260
    /// Opacity of an inactive pane's bar. [06 §5] observed "fainter"; the amount is unknown.
    public static let inactiveOpacity: Double = 0.5
    /// Fill of the domain pill (black over the bar). unknown.
    public static let pillFillOpacity: Double = 0.06
    /// Horizontal padding inside the domain pill. unknown.
    public static let pillHorizontalPadding: Double = 8
    /// Font size of the pill text (`Typography.paneBarPill`, the 13 pt address style, [07 §3]
    /// inferred) and of the button symbols (unknown).
    public static var pillFontSize: Double { Typography.paneBarPill.size }
    public static let symbolFontSize: Double = 12
    /// Opacity of an active pane's bar. inferred (fully drawn).
    public static let activeOpacity: Double = 1
}

/// Geometry of one pane: the bar on top and the page surface below. All frames are in the same
/// coordinate space as `paneFrame` (points, top-left origin).
public struct SplitPaneBarLayout: Equatable, Sendable {
    public var paneFrame: CGRect
    public var barFrame: CGRect
    /// The tab surface: the pane minus the bar. It never overlaps the bar.
    public var pageFrame: CGRect
    public var backButtonFrame: CGRect
    public var forwardButtonFrame: CGRect
    public var closeButtonFrame: CGRect
    /// Centered in the bar and kept clear of the buttons on both sides (so it stays centered).
    public var pillFrame: CGRect

    public init(paneFrame: CGRect) {
        let t = SplitPaneBarTokens.self
        let barHeight = min(t.height, max(0, paneFrame.height))
        self.paneFrame = paneFrame
        barFrame = CGRect(x: paneFrame.minX, y: paneFrame.minY, width: paneFrame.width, height: barHeight)
        pageFrame = CGRect(
            x: paneFrame.minX,
            y: paneFrame.minY + barHeight,
            width: paneFrame.width,
            height: max(0, paneFrame.height - barHeight)
        )
        let buttonY = barFrame.midY - t.buttonSize / 2
        backButtonFrame = CGRect(x: barFrame.minX + t.horizontalPadding, y: buttonY, width: t.buttonSize, height: t.buttonSize)
        forwardButtonFrame = CGRect(x: backButtonFrame.maxX + t.buttonSpacing, y: buttonY, width: t.buttonSize, height: t.buttonSize)
        closeButtonFrame = CGRect(x: barFrame.maxX - t.horizontalPadding - t.buttonSize, y: buttonY, width: t.buttonSize, height: t.buttonSize)
        // The leading group is the wider side; reserving it on both sides keeps the pill centered.
        let sideReserve = forwardButtonFrame.maxX - barFrame.minX + t.buttonSpacing
        let pillWidth = max(0, min(t.pillMaxWidth, barFrame.width - 2 * sideReserve))
        pillFrame = CGRect(
            x: barFrame.midX - pillWidth / 2,
            y: barFrame.midY - t.pillHeight / 2,
            width: pillWidth,
            height: t.pillHeight
        )
    }
}

/// What one pane's top bar shows. Built by `ShellModel.paneBarState(for:)`.
public struct SplitPaneBarState: Equatable, Sendable {
    public var tabID: UUID
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// The pill's domain; nil shows the placeholder (a new, empty pane). [06 §4] observed that
    /// the address shows only the domain.
    public var domain: String?
    /// The pane holds the selected tab. [06 §5] observed that panes have an active state.
    public var isActive: Bool

    public init(tabID: UUID, canGoBack: Bool, canGoForward: Bool, domain: String?, isActive: Bool) {
        self.tabID = tabID
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.domain = domain
        self.isActive = isActive
    }

    /// An inactive pane's bar is fainter. [06 §5] observed.
    public var isDimmed: Bool { !isActive }

    public var opacity: Double {
        isDimmed ? SplitPaneBarTokens.inactiveOpacity : SplitPaneBarTokens.activeOpacity
    }
}

extension ShellModel {
    /// The top bar state of the pane showing `tabID`.
    public func paneBarState(for tabID: UUID) -> SplitPaneBarState {
        let live = sidebar.liveState(for: tabID)
        let domain: String?
        switch SidebarURLBoxContent.make(url: sidebar.linkURL(for: tabID)) {
        case .placeholder: domain = nil
        case .domain(let host, _): domain = host
        }
        return SplitPaneBarState(
            tabID: tabID,
            canGoBack: live?.canGoBack ?? false,
            canGoForward: live?.canGoForward ?? false,
            domain: domain,
            isActive: selectedTabID == tabID
        )
    }

    /// Back in the pane of `tabID`. The pane takes focus first (inferred: a click in a pane
    /// focuses it). [06 §5] observed the button.
    public func paneGoBack(_ tabID: UUID) {
        focusPane(tabID)
        guard let live = sidebar.liveTab(for: tabID) else { return }
        controller.enqueueEngineWork { try? await live.goBack() }
    }

    /// Forward in the pane of `tabID`. [06 §5] observed the button; focusing is inferred.
    public func paneGoForward(_ tabID: UUID) {
        focusPane(tabID)
        guard let live = sidebar.liveTab(for: tabID) else { return }
        controller.enqueueEngineWork { try? await live.goForward() }
    }

    /// The pill opens the pane command bar in ⌘L mode, prefilled with that pane's address.
    /// [06 §5] observed the pill, [06 §6] observed that a split's bar opens inside its pane;
    /// the ⌘L prefill is inferred from the sidebar address box.
    public func paneOpenAddressBar(_ tabID: UUID) {
        focusPane(tabID)
        presentCommandBarInPane(tabID, currentURL: sidebar.linkURL(for: tabID))
    }

    /// ✕ closes this pane: the pane is focused and then closed like Close this Split Pane (⌃⇧-).
    /// [06 §5] observed.
    public func paneClose(_ tabID: UUID) {
        guard activeSplitLayout?.root.tabIDs.contains(tabID) == true else { return }
        focusPane(tabID)
        closeSplitPane()
    }
}
