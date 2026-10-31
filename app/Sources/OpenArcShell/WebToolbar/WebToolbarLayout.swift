import CoreGraphics
import Foundation
import OpenArcDesign

// Pure geometry and content of the web toolbar (plan B43) and of the split panes' top bars, which
// are the same strip with fewer buttons. Frames are top-left based, in the coordinate space of
// the `barFrame` passed in.
//
// Spec sources (docs/arc-spec/):
//   [06 §17.2] observed: buttons 32 × 24, 4 pt from the top, 5 pt side padding, leading pitch 37;
//              trailing site controls 32 × 28 and split menu 32 × 24, pitch 36; the center group
//              (copy link · lock for http · domain · two hidden spacers) centered on the panel.
//   [06 §17.6] observed: split panes each get a bar; the active pane adds reload, site controls,
//              split menu and a close ✕ at the far right; an inactive pane shows back, forward,
//              the domain group and ✕ only.
//   [06 §5]    observed: with the toolbar off every pane still has a top bar with back, forward,
//              the centered domain pill and ✕.

/// One button of the web toolbar.
public enum WebToolbarItem: String, Hashable, Sendable, CaseIterable {
    /// Shows the hidden sidebar again (pinned). First item while the sidebar is hidden. [06 §17.2]
    case showSidebar
    case back
    case forward
    /// Reload; a stop ✕ while loading. [06 §17.2] observed.
    case reload
    /// "Translation Options": only while the page can be (or is) translated, left of the site
    /// controls (32 × 24, pitch 36). [06 §19.1] observed. B47.
    case translate
    /// Opens the Site Control Center. [06 §17.3] observed.
    case siteControls
    /// Native menu: Add Right / Left / Top / Bottom Split. [06 §17.3] observed.
    case splitMenu
    /// Closes this split pane. [06 §17.6] observed.
    case closePane
}

/// What a bar belongs to.
public enum WebToolbarRole: Hashable, Sendable {
    /// The single web panel (toolbar on).
    case page
    /// A split pane; `isActive` = it holds the selected tab.
    case pane(isActive: Bool)
}

/// The buttons left and right of the center group, in display order.
public struct WebToolbarItems: Equatable, Sendable {
    public var leading: [WebToolbarItem]
    public var trailing: [WebToolbarItem]

    public init(leading: [WebToolbarItem], trailing: [WebToolbarItem]) {
        self.leading = leading
        self.trailing = trailing
    }

    /// The buttons for a bar.
    /// - `isToolbarShown`: View ▸ Show Toolbar. Off, only split panes have a bar (back, forward,
    ///   ✕; [06 §5] observed) and the single page has none ([06 §17.1] observed).
    /// - `showsSidebarButton`: the sidebar is hidden and this bar is the one at the panel's top
    ///   left. [06 §17.2] observed for the single page; for split panes inferred (the pane that
    ///   takes the panel's top-left corner gets it).
    /// - `showsTranslate`: the bar's page offers translation; the bar then leads its right group
    ///   with the translation button ([06 §19.1] observed for the single page; for the active split
    ///   pane inferred, it carries the site controls too).
    public static func make(role: WebToolbarRole, isToolbarShown: Bool, showsSidebarButton: Bool,
                            showsTranslate: Bool = false) -> WebToolbarItems {
        guard isToolbarShown else {
            switch role {
            case .page: return WebToolbarItems(leading: [], trailing: [])
            case .pane: return WebToolbarItems(leading: [.back, .forward], trailing: [.closePane])
            }
        }
        let sidebar: [WebToolbarItem] = showsSidebarButton ? [.showSidebar] : []
        let translate: [WebToolbarItem] = showsTranslate ? [.translate] : []
        switch role {
        case .page:
            return WebToolbarItems(leading: sidebar + [.back, .forward, .reload], trailing: translate + [.siteControls, .splitMenu])
        case .pane(isActive: true):
            return WebToolbarItems(leading: sidebar + [.back, .forward, .reload], trailing: translate + [.siteControls, .splitMenu, .closePane])
        case .pane(isActive: false):
            return WebToolbarItems(leading: sidebar + [.back, .forward], trailing: [.closePane])
        }
    }
}

/// Frames of one bar's buttons and center group.
public struct WebToolbarLayout: Equatable, Sendable {
    public var barFrame: CGRect
    public var items: WebToolbarItems
    public private(set) var itemFrames: [WebToolbarItem: CGRect] = [:]
    /// Copy link button, the first item of the center group.
    public private(set) var copyLinkFrame: CGRect = .zero
    /// The struck-through lock (http pages only); nil otherwise.
    public private(set) var lockFrame: CGRect?
    /// The domain (or full URL) text, 16 tall, truncated to fit between the side groups.
    public private(set) var domainFrame: CGRect = .zero
    /// The whole center group including its two hidden trailing spacers; centered on the bar.
    public private(set) var centerGroupFrame: CGRect = .zero

    /// - Parameters:
    ///   - domainTextWidth: the natural width of the domain text (measured by the view).
    ///   - showsInsecureLock: the page is plain http. [06 §17.2] observed.
    public init(barFrame: CGRect, items: WebToolbarItems, domainTextWidth: CGFloat, showsInsecureLock: Bool) {
        typealias T = Metrics.WebToolbar
        self.barFrame = barFrame
        self.items = items

        // Leading: 32 × 24 at a 37 pt pitch, 5 pt from the left edge, 4 pt from the top.
        for (index, item) in items.leading.enumerated() {
            itemFrames[item] = CGRect(
                x: barFrame.minX + T.horizontalPadding + Double(index) * T.navButtonPitch,
                y: barFrame.minY + T.navButtonTopInset,
                width: T.navButtonSize.width, height: T.navButtonSize.height
            )
        }
        // Trailing: laid out from the right edge. The close ✕ sits 32 right of the split menu,
        // the other neighbors 36 apart. [06 §17.2, §17.6] observed.
        var right = barFrame.maxX - T.horizontalPadding
        for (offset, item) in items.trailing.reversed().enumerated() {
            let size = item == .siteControls ? T.siteControlsButtonSize : T.trailingButtonSize
            let top = item == .siteControls ? T.siteControlsButtonTopInset : T.trailingButtonTopInset
            if offset > 0 {
                let rightNeighbor = items.trailing[items.trailing.count - offset]
                right -= (rightNeighbor == .closePane ? T.closePanePitch : T.trailingButtonPitch) - size.width
            }
            let frame = CGRect(x: right - size.width, y: barFrame.minY + top, width: size.width, height: size.height)
            itemFrames[item] = frame
            right = frame.minX
        }

        // Center group, centered on the bar and kept clear of both side groups.
        let leadingEdge = items.leading.compactMap { itemFrames[$0]?.maxX }.max() ?? barFrame.minX + T.horizontalPadding
        let trailingEdge = items.trailing.compactMap { itemFrames[$0]?.minX }.min() ?? barFrame.maxX - T.horizontalPadding
        let mid = barFrame.midX
        let halfRoom = max(0, min(mid - leadingEdge, trailingEdge - mid) - T.centerGroupMinimumGap)
        let button = T.centerButtonSize
        let fixed = button * Double(1 + (showsInsecureLock ? 1 : 0) + T.centerTrailingSpacerCount)
        let textWidth = max(0, min(Double(domainTextWidth), 2 * halfRoom - fixed))
        let groupWidth = fixed + textWidth
        let buttonY = barFrame.minY + (min(T.height, barFrame.height) - button) / 2
        var x = mid - groupWidth / 2
        centerGroupFrame = CGRect(x: x, y: buttonY, width: groupWidth, height: button)
        copyLinkFrame = CGRect(x: x, y: buttonY, width: button, height: button)
        x += button
        if showsInsecureLock {
            lockFrame = CGRect(x: x, y: buttonY, width: button, height: button)
            x += button
        }
        domainFrame = CGRect(
            x: x, y: barFrame.minY + (min(T.height, barFrame.height) - T.domainTextHeight) / 2,
            width: textWidth, height: T.domainTextHeight
        )
    }

    public func frame(of item: WebToolbarItem) -> CGRect? { itemFrames[item] }

    /// The hover pill behind the domain text: the text plus 6 pt each side, 23 tall, centered on
    /// it. [06 §17.5] observed.
    public var domainHoverFrame: CGRect {
        typealias T = Metrics.WebToolbar
        return CGRect(
            x: domainFrame.minX - T.domainHoverPillPadding,
            y: domainFrame.midY - T.domainHoverPillHeight / 2,
            width: domainFrame.width + 2 * T.domainHoverPillPadding,
            height: T.domainHoverPillHeight
        )
    }
}

/// What one bar shows for its tab. Built by `ShellModel.webToolbarState(for:)`.
public struct WebToolbarState: Equatable, Sendable {
    public var tabID: UUID?
    public var url: URL?
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    /// The pane (or page) holds the selected tab.
    public var isActive: Bool

    public init(tabID: UUID?, url: URL?, canGoBack: Bool = false, canGoForward: Bool = false, isLoading: Bool = false, isActive: Bool = true) {
        self.tabID = tabID
        self.url = url
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.isActive = isActive
    }

    /// Plain http pages get the red struck-through lock; https shows none. [06 §17.2] observed.
    public var showsInsecureLock: Bool { SidebarURLBoxContent.showsInsecureLock(url: url) }

    /// The center text: the host, or with "Show full URL when Toolbar is enabled" the address
    /// without its scheme (`10.20.0.59:8716/black.html`). [06 §17.2] observed. A tab without a
    /// page shows the address box placeholder (inferred).
    public func displayText(showsFullURL: Bool) -> String {
        WebToolbarText.display(url: url, showsFullURL: showsFullURL)
    }
}

enum WebToolbarText {
    static func display(url: URL?, showsFullURL: Bool) -> String {
        guard let url else { return SidebarURLBoxContent.placeholderText }
        guard showsFullURL else {
            if let host = SidebarURLBoxContent.displayHost(url) { return host }
            return url.absoluteString
        }
        let text = url.absoluteString
        if let range = text.range(of: "://") { return String(text[range.upperBound...]) }
        // `about:blank`, `data:` and the like have no "//": drop only the scheme. inferred.
        if let scheme = url.scheme, text.hasPrefix(scheme + ":") { return String(text.dropFirst(scheme.count + 1)) }
        return text
    }
}
