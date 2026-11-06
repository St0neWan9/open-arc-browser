import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The folder hover quick list (B76). [06 §14] observed: hovering a folder opens a small list of
// that folder's items with a "Search <folder>…" field on top and, per item, its title and a
// relative time; the same in the docked sidebar and in the floating (peek) one. [06 §33] observed
// (issue #4): only collapsed folders have one; a system-menu-like glass panel (not the theme
// bubble), no arrow, right of the sidebar and centered on the folder row; a search bar with a
// separator; two-line rows (title, "2 months ago") with a globe glyph; newest first; the first row
// highlighted. The dismissal rules are inferred.

/// Local metrics of the quick list. [06 §33] observed (single 2× capture) unless noted.
enum FolderQuickListTokens {
    /// Hover time before the list opens: the same as the tab hover card ([06 §12] observed ≈ 0.5 s
    /// there). inferred.
    static let showDelay: Double = Motion.hoverCardDelay
    /// Grace period after the pointer leaves the row before the list closes, long enough to cross
    /// the gap into the bubble. inferred.
    static let dismissDelay: Double = 0.3
    static let width: CGFloat = 240
    static let cornerRadius: CGFloat = 12
    /// Search bar height, then a 1 pt full-width separator.
    static let searchHeight: CGFloat = 48
    static let separatorHeight: CGFloat = 1
    /// Gap between the separator and the first row, and below the last row.
    static let listInset: CGFloat = 4
    /// Two-line rows: title, then the relative time.
    static let rowHeight: CGFloat = 45
    /// Rows are inset from the panel's sides.
    static let rowInset: CGFloat = 4
    static let rowCornerRadius: CGFloat = 6
    /// Globe glyph left of each row.
    static let iconSize: CGFloat = 16
    /// Space between the sidebar's right edge and the panel.
    static let sidebarGap: CGFloat = 6
    /// Tallest panel; longer lists scroll (≈ 6 rows).
    static let maxHeight: CGFloat = 320

    /// Panel height for `rowCount` matching rows (an empty result shows one "No matches" row).
    /// Shorter lists make a shorter panel (inferred).
    static func height(rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(rowCount, 1))
        return min(maxHeight, searchHeight + separatorHeight + listInset * 2 + rows * rowHeight)
    }

    /// The panel's frame in window coordinates (top-left origin): right of the sidebar, centered
    /// on the folder row and kept inside the window. [06 §33] observed placement; the clamping
    /// inferred.
    static func frame(anchor: CGRect, sidebarMaxX: CGFloat, size: CGSize, window: CGSize) -> CGRect {
        let margin: CGFloat = 8
        var y = anchor.midY - size.height / 2
        y = min(max(y, margin), max(margin, window.height - margin - size.height))
        return CGRect(x: sidebarMaxX + sidebarGap, y: y, width: size.width, height: size.height)
    }
}

/// One item of a folder's quick list.
struct FolderQuickListRow: Identifiable, Equatable {
    var tabID: UUID
    var title: String
    /// Time since the tab was last active, as Arc writes it ("2 months ago"). [06 §33] observed.
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
    /// and diacritics, most recently active first. The "Search <folder>…" field is observed
    /// [06 §14]; the order is observed [06 §33]; the matching is inferred.
    static func rows(folderID: UUID, workspace: WorkspaceState, query: String, now: Date) -> [FolderQuickListRow] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let ordered = tabs(inFolder: folderID, workspace: workspace).enumerated()
            .sorted { $0.element.lastActiveAt != $1.element.lastActiveAt ? $0.element.lastActiveAt > $1.element.lastActiveAt : $0.offset < $1.offset }
            .map(\.element)
        return ordered.compactMap { tab in
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

    /// Relative time in words: "2 months ago", "10 months ago", "1 year ago" ([06 §33] observed);
    /// the shorter units follow the same pattern (inferred), "just now" under a minute.
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3_600.0, day = 86_400.0
        func ago(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour: return ago(Int(seconds / minute), "minute")
        case ..<day: return ago(Int(seconds / hour), "hour")
        case ..<(7 * day): return ago(Int(seconds / day), "day")
        case ..<(30 * day): return ago(Int(seconds / (7 * day)), "week")
        case ..<(365 * day): return ago(Int(seconds / (30 * day)), "month")
        default: return ago(Int(seconds / (365 * day)), "year")
        }
    }
}

// MARK: - View

/// The panel's content: search bar, separator, then one two-line row per item (globe, title,
/// relative time); the first row is highlighted as the Return target, and a hovered row too.
/// [06 §33] observed. Plain system ink: the panel is a system-menu-like glass, not themed.
struct FolderQuickListView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let folderID: UUID
    @State private var hoveredRow: UUID?

    var body: some View {
        let rows = viewModel.quickListRows(folderID: folderID)
        let title = viewModel.workspace.folders[folderID]?.title ?? ""
        let t = FolderQuickListTokens.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(FolderQuickList.searchPlaceholder(folderTitle: title), text: $viewModel.quickListQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { if let first = rows.first { viewModel.openFromQuickList(first.tabID) } }
                    .accessibilityIdentifier("openarc.sidebar.folderQuickList.search")
            }
            .padding(.horizontal, 14)
            .frame(height: t.searchHeight)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: t.separatorHeight)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: t.rowHeight, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isHighlighted: hoveredRow == row.tabID || (hoveredRow == nil && index == 0))
                    }
                }
                .padding(.vertical, t.listInset)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: t.width, height: t.height(rowCount: rows.count), alignment: .topLeading)
        .onHover { viewModel.quickListHoverChanged($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.folderQuickList")
    }

    private func rowView(_ row: FolderQuickListRow, isHighlighted: Bool) -> some View {
        let t = FolderQuickListTokens.self
        return HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: t.iconSize, height: t.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.relativeTime)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: t.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: t.rowCornerRadius, style: .continuous)
                .fill(isHighlighted ? Color.primary.opacity(0.08) : .clear)
        )
        .padding(.horizontal, t.rowInset)
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

/// Shows the quick list of `folderID` in a floating panel right of the sidebar, centered on the
/// folder row, while `folderID` is set ([06 §33] observed). Placed over the whole sidebar (root
/// coordinate space, top-left origin), so `anchor` (the row's fill, root space) converts directly
/// and this view's right edge is the sidebar's. The panel is a child window that only takes the
/// keyboard when its search field is clicked, so hovering never steals focus from the page
/// (inferred: Arc shows the caret in the field at once).
struct FolderQuickListPresenter: NSViewRepresentable {
    let viewModel: SidebarViewModel
    let folderID: UUID?
    let anchor: CGRect?
    let rowCount: Int
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
        c.state = folderID.flatMap { id in anchor.map { .init(folderID: id, anchor: $0, rowCount: rowCount, isDark: isDark) } }
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
            let sidebarInWindow = view.convert(view.bounds, to: nil)
            let outer = t.frame(anchor: anchor, sidebarMaxX: sidebarInWindow.maxX - containerInWindow.minX, size: size,
                                window: containerInWindow.size)
            let panel = self.panel ?? makePanel()
            if shown != state {
                let content = FolderQuickListView(viewModel: viewModel, folderID: state.folderID)
                    .overlay(RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
                    .clipShape(RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous))
                    .environment(\.colorScheme, state.isDark ? .dark : .light)
                host?.rootView = AnyView(content)
                panel.appearance = NSAppearance(named: state.isDark ? .darkAqua : .aqua)
            }
            let inWindow = CGRect(x: containerInWindow.minX + outer.minX, y: containerInWindow.maxY - outer.maxY,
                                  width: outer.width, height: outer.height)
            let screenFrame = window.convertToScreen(inWindow)
            if panel.frame != screenFrame || shown != state {
                panel.setFrame(screenFrame, display: true)
                effect?.maskImage = FloatingBubbleController.maskImage(size: outer.size, cornerRadius: t.cornerRadius, arrow: nil)
                panel.invalidateShadow()
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
            // A system-menu-like glass with a soft shadow. [06 §33] observed (not the theme bubble).
            panel.hasShadow = true
            let effect = NSVisualEffectView()
            effect.material = .menu
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
