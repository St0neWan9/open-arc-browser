import Foundation
import OpenArcModel
import OpenArcEngine

// The shell's windows as the engine's extensions see them (plan B126, `BrowserEngine.setWindows`):
// `chrome.windows.get*` answers with them and `chrome.action.openPopup()` (B125) opens over the
// active tab of the focused one. [00 §A] inferred (analysis): extensions work in Arc; how Arc
// reports its windows to them is not in the spec, so everything below is inferred:
// - a browser window is a `normal` window, a Little Arc window a `popup` one;
// - a browser window's tabs are the live tabs of its selected Space (Favorites, then Pinned, then
//   Today), plus the tabs it shows; a Little Arc window's tab is its page;
// - an incognito window belongs to the incognito context of its profile only;
// - the list is ordered most recently focused first; a window is focused while it is key.
//
// One reporter per app (the app's `WorkspaceController`; incognito controllers use their
// parent's). Changes are coalesced: a report is computed once per main-actor turn and sent only
// when it differs from the last one.

/// A window the reporter lists: a browser window (`ShellModel`) or a Little Arc window.
@MainActor
protocol EngineWindowSource: AnyObject {
    /// Stable for the window's life.
    var engineWindowID: UUID { get }
    /// The window as the engine sees it now; nil leaves it out (no profile yet, closed).
    func engineWindowInfo(isFocused: Bool) -> EngineWindowInfo?
}

@MainActor
final class EngineWindowReporter {
    private struct WeakSource {
        weak var source: (any EngineWindowSource)?
    }

    private let engine: any BrowserEngine
    private var sources: [WeakSource] = []
    /// Window ids, most recently focused first.
    private var focusOrder: [UUID] = []
    /// The key window, if it is one of ours.
    private var keyWindowID: UUID?
    private var lastSent: [EngineWindowInfo]?
    private var isScheduled = false
    private var sending: Task<Void, Never>?
    private var isStopped = false

    init(engine: any BrowserEngine) {
        self.engine = engine
    }

    /// Lists `source` from now on (a window opened).
    func register(_ source: any EngineWindowSource) {
        sources.removeAll { $0.source == nil }
        guard !sources.contains(where: { $0.source === source }) else { return }
        sources.append(WeakSource(source: source))
        setNeedsReport()
    }

    /// Stops listing `source` (its window closed).
    func unregister(_ source: any EngineWindowSource) {
        sources.removeAll { $0.source == nil || $0.source === source }
        focusOrder.removeAll { $0 == source.engineWindowID }
        if keyWindowID == source.engineWindowID { keyWindowID = nil }
        setNeedsReport()
    }

    /// The window became (or stopped being) the key window.
    func windowKeyStateChanged(_ source: any EngineWindowSource, isKey: Bool) {
        let id = source.engineWindowID
        if isKey {
            keyWindowID = id
            focusOrder.removeAll { $0 == id }
            focusOrder.insert(id, at: 0)
        } else if keyWindowID == id {
            keyWindowID = nil
        }
        setNeedsReport()
    }

    /// Something a window reports changed (tabs, selection, frame): report again in a later turn.
    func setNeedsReport() {
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        Task { @MainActor [weak self] in self?.reportNow() }
    }

    /// The list as it stands, most recently focused first; windows never focused follow in the
    /// order they opened.
    var currentWindows: [EngineWindowInfo] {
        sources.removeAll { $0.source == nil }
        let live = sources.compactMap(\.source)
        let rank = Dictionary(focusOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = live.enumerated().sorted { a, b in
            let ra = rank[a.element.engineWindowID] ?? (focusOrder.count + a.offset)
            let rb = rank[b.element.engineWindowID] ?? (focusOrder.count + b.offset)
            return ra < rb
        }
        return ordered.compactMap { $0.element.engineWindowInfo(isFocused: $0.element.engineWindowID == keyWindowID) }
    }

    /// Computes the list and sends it when it changed. Sends keep their order.
    func reportNow() {
        isScheduled = false
        guard !isStopped else { return }
        let windows = currentWindows
        guard windows != lastSent else { return }
        lastSent = windows
        let previous = sending
        let engine = self.engine
        sending = Task { @MainActor in
            await previous?.value
            await engine.setWindows(windows)
        }
    }

    /// Waits until scheduled reports reached the engine. For tests.
    func settle() async {
        if isScheduled { reportNow() }
        await sending?.value
    }

    func stop() {
        isStopped = true
    }
}

// MARK: - Browser windows

extension ShellModel: EngineWindowSource {
    var engineWindowID: UUID { windowID }

    /// A browser window: the live tabs of its selected Space, the tabs it shows active. Not listed
    /// before it knows its profile.
    func engineWindowInfo(isFocused: Bool) -> EngineWindowInfo? {
        guard isBrowserWindow, let profileID = sidebar.currentProfileID else { return nil }
        let shown = sidebar.onScreenTabIDs
        var modelTabs: [UUID] = []
        if let spaceID = selectedSpaceID {
            let ws = workspace
            modelTabs += ws.favorites(profileID: profileID).map(\.id)
            let inSpace = ws.allTabs(inSpace: spaceID)
            let order: (TabNode, TabNode) -> Bool = { SortKey.order(($0.sortKey, $0.id), ($1.sortKey, $1.id)) }
            modelTabs += inSpace.filter { if case .pinned = $0.location { return true } else { return false } }.sorted(by: order).map(\.id)
            modelTabs += inSpace.filter { if case .today = $0.location { return true } else { return false } }.sorted(by: order).map(\.id)
        }
        for id in shown.sorted(by: { $0.uuidString < $1.uuidString }) where !modelTabs.contains(id) { modelTabs.append(id) }
        let engineTabs = modelTabs.compactMap { controller.liveTab(for: $0)?.id }
        let active = shown.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { controller.liveTab(for: $0)?.id }
        let frame = windowFrame
        return EngineWindowInfo(
            id: windowID, profileID: profileID, isOffTheRecord: controller.isOffTheRecord,
            isFocused: isFocused, isPopup: false,
            x: frame.x, y: frame.y, width: frame.width, height: frame.height,
            tabIDs: engineTabs, activeTabIDs: active
        )
    }
}

// MARK: - Little Arc windows

extension LittleArcModel: EngineWindowSource {
    var engineWindowID: UUID { windowID }

    /// A Little Arc window: a popup window with its page, once it has one. inferred.
    func engineWindowInfo(isFocused: Bool) -> EngineWindowInfo? {
        guard phase != .closed, let profileID = pageProfileID ?? shell.sidebar.currentProfileID else { return nil }
        let tabs = liveTab.map { [$0.id] } ?? []
        let frame = windowFrame
        return EngineWindowInfo(
            id: windowID, profileID: profileID, isOffTheRecord: false,
            isFocused: isFocused, isPopup: true,
            x: frame.x, y: frame.y, width: frame.width, height: frame.height,
            tabIDs: tabs, activeTabIDs: tabs
        )
    }
}

/// A window frame in screen points, AppKit coordinates (`NSWindow.frame`), without AppKit.
struct EngineWindowFrame: Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
}
