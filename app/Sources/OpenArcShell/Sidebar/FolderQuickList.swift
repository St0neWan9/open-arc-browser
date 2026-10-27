import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The folder hover quick list (B76). [06 §14] observed: hovering a folder opens a small list of
// that folder's items with a "Search <folder>…" field on top and, per item, its title and a
// relative time; the same in the docked sidebar and in the floating (peek) one. Everything else
// here is inferred and labeled: which folders have one, the order, the time format, the placement
// (a bubble right of the row, like "Choose a Theme" [07 §12]) and the dismissal rules.

/// Local metrics of the quick list. All inferred unless noted: [06 §14] has no measurements.
enum FolderQuickListTokens {
    /// Hover time before the list opens: the same as the tab hover card ([06 §12] observed ≈ 0.5 s
    /// there). inferred.
    static let showDelay: Double = Motion.hoverCardDelay
    /// Grace period after the pointer leaves the row before the list closes, long enough to cross
    /// the gap into the bubble. inferred.
    static let dismissDelay: Double = 0.3
    static let width: CGFloat = 260
    static let cornerRadius: CGFloat = 14
    static let padding: CGFloat = 6
    static let searchHeight: CGFloat = 32
    static let rowHeight: CGFloat = 32
    static let rowCornerRadius: CGFloat = 8
    static let iconSize: CGFloat = 16
    /// Rows shown before the list scrolls.
    static let maxVisibleRows = 8

    /// Bubble height for `rowCount` matching rows (an empty result shows one "No matches" row).
    static func height(rowCount: Int) -> CGFloat {
        let rows = CGFloat(min(max(rowCount, 1), maxVisibleRows))
        return padding * 2 + searchHeight + rows * rowHeight
    }
}

/// One item of a folder's quick list.
struct FolderQuickListRow: Identifiable, Equatable {
    var tabID: UUID
    var title: String
    /// Compact time since the tab was last active ("now", "5m", "3h", "2d", "4w", "6mo", "1y").
    var relativeTime: String

    var id: UUID { tabID }
}

/// Pure content of the quick list.
enum FolderQuickList {
    /// Every live tab in the folder, nested folders included, in sidebar order (depth first).
    /// inferred: [06 §14] shows "items"; flattening sub-folders keeps the list one level deep.
    static func tabs(inFolder folderID: UUID, workspace: WorkspaceState) -> [TabNode] {
        guard let folder = workspace.folders[folderID], !folder.meta.isTombstone else { return [] }
        var result: [TabNode] = []
        var visited: Set<UUID> = []
        func walk(_ id: UUID) {
            guard visited.insert(id).inserted else { return }
            for item in workspace.pinnedChildren(spaceID: folder.spaceID, folderID: id) {
                switch item {
                case .tab(let tab): result.append(tab)
                case .folder(let child): walk(child.id)
                }
            }
        }
        walk(folderID)
        return result
    }

    /// Rows for `query`: tabs whose title or URL contains every word of the query, ignoring case
    /// and diacritics. The "Search <folder>…" field is observed [06 §14]; the matching is inferred.
    static func rows(folderID: UUID, workspace: WorkspaceState, query: String, now: Date) -> [FolderQuickListRow] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return tabs(inFolder: folderID, workspace: workspace).compactMap { tab in
            let title = tab.displayTitle.isEmpty ? (tab.url?.host ?? "New Tab") : tab.displayTitle
            let haystack = title + " " + (tab.url?.absoluteString ?? "")
            guard words.allSatisfy({ haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { return nil }
            return FolderQuickListRow(tabID: tab.id, title: title, relativeTime: relativeTime(from: tab.lastActiveAt, to: now))
        }
    }

    /// Placeholder of the search field. [06 §14] observed ("Search <folder name>…").
    static func searchPlaceholder(folderTitle: String) -> String {
        "Search \(folderTitle)…"
    }

    /// Compact relative time. [06 §14] observed "relative time"; the format is inferred.
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3_600.0, day = 86_400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(7 * day): return "\(Int(seconds / day))d"
        case ..<(30 * day): return "\(Int(seconds / (7 * day)))w"
        case ..<(365 * day): return "\(Int(seconds / (30 * day)))mo"
        default: return "\(Int(seconds / (365 * day)))y"
        }
    }
}

// MARK: - View

/// The list inside the bubble: search field, then one row per item (favicon, title, time).
struct FolderQuickListView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let folderID: UUID
    @State private var hoveredRow: UUID?

    var body: some View {
        let palette = viewModel.palette
        let ink = palette.floatingPanelInk
        let rows = viewModel.quickListRows(folderID: folderID)
        let title = viewModel.workspace.folders[folderID]?.title ?? ""
        let t = FolderQuickListTokens.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.swiftUI.opacity(0.45))
                TextField(FolderQuickList.searchPlaceholder(folderTitle: title), text: $viewModel.quickListQuery)
                    .textFieldStyle(.plain)
                    .font(Typography.panelRowTitle.font)
                    .foregroundStyle(ink.swiftUI)
                    .onSubmit { if let first = rows.first { viewModel.openFromQuickList(first.tabID) } }
                    .accessibilityIdentifier("openarc.sidebar.folderQuickList.search")
            }
            .padding(.horizontal, 8)
            .frame(height: t.searchHeight)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("No matches")
                            .textStyle(Typography.panelRowDetail, ink: ink)
                            .frame(maxWidth: .infinity, minHeight: t.rowHeight, alignment: .leading)
                            .padding(.horizontal, 8)
                    }
                    ForEach(rows) { row in rowView(row, ink: ink, palette: palette) }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(t.padding)
        .frame(width: t.width, height: t.height(rowCount: rows.count), alignment: .topLeading)
        .onHover { viewModel.quickListHoverChanged($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.folderQuickList")
    }

    private func rowView(_ row: FolderQuickListRow, ink: RGBAColor, palette: ThemePalette) -> some View {
        let t = FolderQuickListTokens.self
        return HStack(spacing: 8) {
            SidebarFaviconView(pngData: viewModel.faviconImage(for: row.tabID), size: t.iconSize,
                               tint: ink.swiftUI.opacity(0.2), placeholder: .roundedSquare)
            Text(row.title)
                .textStyle(Typography.panelRowTitle, ink: ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(row.relativeTime)
                .textStyle(Typography.panelRowDetail, ink: ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: t.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: t.rowCornerRadius, style: .continuous)
                .fill(hoveredRow == row.tabID ? palette.floatingPanelSelection.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hoveredRow = $0 ? row.tabID : (hoveredRow == row.tabID ? nil : hoveredRow) }
        .onTapGesture { viewModel.openFromQuickList(row.tabID) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { viewModel.openFromQuickList(row.tabID) }
        .accessibilityIdentifier("openarc.sidebar.folderQuickList.row.\(row.tabID.uuidString)")
    }
}

// MARK: - Presenter

/// Shows the quick list of `folderID` in a floating bubble right of the folder row, while
/// `folderID` is set. Placed over the whole sidebar (root coordinate space, top-left origin), so
/// `anchor` (the row's fill, root space) converts directly. The bubble is a child panel that only
/// takes the keyboard when its search field is clicked, so hovering never steals focus from the
/// page. Placement: `FloatingBubbleLayout.attached(.trailing)` ([07 §12] observed for "Choose a
/// Theme"; using it here is inferred).
struct FolderQuickListPresenter: NSViewRepresentable {
    let viewModel: SidebarViewModel
    let folderID: UUID?
    let anchor: CGRect?
    let rowCount: Int
    let tint: RGBAColor
    let isDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        let c = context.coordinator
        c.viewModel = viewModel
        c.state = folderID.flatMap { id in anchor.map { .init(folderID: id, anchor: $0, rowCount: rowCount, tint: tint, isDark: isDark) } }
        c.schedule()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.state = nil
        coordinator.hide()
    }

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        struct State: Equatable {
            var folderID: UUID
            var anchor: CGRect
            var rowCount: Int
            var tint: RGBAColor
            var isDark: Bool
        }

        weak var view: NSView?
        weak var viewModel: SidebarViewModel?
        var state: State?
        private var panel: FloatingBubblePanel?
        private var host: FloatingBubbleHostingView<AnyView>?
        private var effect: NSVisualEffectView?
        private var shown: State?
        /// Event monitors while the list shows; the panel's key observers for the coordinator's life.
        private var monitors = QuickListObserverBag()
        private let observers = QuickListObserverBag()
        private var isScheduled = false

        /// Coalesced to the next run-loop turn: windows are never touched during a SwiftUI update.
        func schedule() {
            guard !isScheduled else { return }
            isScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.isScheduled = false
                    self?.apply()
                }
            }
        }

        func hide() {
            removeMonitors()
            shown = nil
            guard let panel else { return }
            let parent = panel.parent, wasKey = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            if wasKey { parent?.makeKey() }
        }

        private func apply() {
            guard let state, let viewModel, let view, let window = view.window, let contentView = window.contentView else {
                hide()
                return
            }
            let t = FolderQuickListTokens.self
            let size = CGSize(width: t.width, height: t.height(rowCount: state.rowCount))
            let containerInWindow = contentView.convert(contentView.bounds, to: nil)
            let anchorInWindow = view.convert(state.anchor, to: nil)
            let anchor = CGRect(x: anchorInWindow.minX - containerInWindow.minX, y: containerInWindow.maxY - anchorInWindow.maxY,
                                width: anchorInWindow.width, height: anchorInWindow.height)
            let frame = FloatingBubbleLayout.attached(anchor: anchor, side: .trailing, size: size,
                                                      container: CGRect(origin: .zero, size: containerInWindow.size),
                                                      cornerRadius: t.cornerRadius)
            let outer = frame.outerFrame
            let panel = self.panel ?? makePanel()
            if shown != state {
                let content = FolderQuickListView(viewModel: viewModel, folderID: state.folderID)
                host?.rootView = AnyView(FloatingBubbleChrome(size: size, cornerRadius: t.cornerRadius, arrow: frame.arrow,
                                                              tint: state.tint, isDark: state.isDark) { content })
                panel.appearance = NSAppearance(named: state.isDark ? .darkAqua : .aqua)
            }
            let inWindow = CGRect(x: containerInWindow.minX + outer.minX, y: containerInWindow.maxY - outer.maxY,
                                  width: outer.width, height: outer.height)
            let screenFrame = window.convertToScreen(inWindow)
            if panel.frame != screenFrame || shown != state {
                panel.setFrame(screenFrame, display: true)
                effect?.maskImage = FloatingBubbleController.maskImage(size: outer.size, cornerRadius: t.cornerRadius, arrow: frame.arrow)
            }
            shown = state
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            if !panel.isVisible { panel.orderFront(nil) }
            // Hover tracking may not reach a child panel that is not key: before closing the list
            // the view model also asks whether the pointer is over it.
            viewModel.quickListPointerProbe = { [weak panel] in
                guard let panel, panel.isVisible else { return false }
                return panel.frame.contains(NSEvent.mouseLocation)
            }
            installMonitors()
        }

        private func makePanel() -> FloatingBubblePanel {
            let panel = FloatingBubblePanel(contentRect: .zero)
            // Key only when the search field asks for it (`becomesKeyOnlyIfNeeded`), never on hover.
            panel.allowsKey = true
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            let host = FloatingBubbleHostingView(rootView: AnyView(EmptyView()))
            host.autoresizingMask = [.width, .height]
            host.sizingOptions = []
            effect.addSubview(host)
            panel.contentView = effect
            let center = NotificationCenter.default
            observers.observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel?.quickListFocusChanged(true) }
            })
            observers.observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel?.quickListFocusChanged(false) }
            })
            self.panel = panel
            self.effect = effect
            self.host = host
            return panel
        }

        /// A click outside the bubble or Esc closes it. inferred (like the other bubbles).
        private func installMonitors() {
            guard monitors.monitors.isEmpty else { return }
            if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
                    if panel.frame.contains(location) || event.window === panel { return }
                    self.viewModel?.dismissQuickList()
                }
                return event
            }) { monitors.monitors.append(down) }
            if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.panel?.isVisible == true, event.keyCode == 53 else { return false }
                    self.viewModel?.dismissQuickList()
                    return true
                }
                return handled ? nil : event
            }) { monitors.monitors.append(key) }
        }

        private func removeMonitors() {
            monitors = QuickListObserverBag()
        }
    }
}

/// Removes its event monitors and notification observers when released.
private final class QuickListObserverBag {
    var monitors: [Any] = []
    var observers: [NSObjectProtocol] = []
    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
