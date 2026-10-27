import Foundation
import Combine
import OpenArcEngine

// Find in page (plan B25). Menu items: [01 §Edit] Find ▸ (Find… / Find Next / Find Previous / Use
// Selection to Find) observed; keys [02 §页面与导航] ⌘F / ⌘G / ⇧⌘G observed. The bar itself is not
// in the spec: its look, its place (top right of the focused web panel or pane), Enter / ⇧Enter,
// the "n of m" count and Escape closing it are our own design (inferred, browser convention).
//
// One find state per tab (inferred, like Chrome): switching tabs shows the other tab's state, and
// a tab keeps its open bar and query while another tab is selected. In a split the selected tab
// is the focused pane, so the bar always acts on the focused pane.

/// The find state of one tab.
public struct FindBarState: Equatable, Sendable {
    /// The bar is showing for this tab.
    public var isOpen = false
    /// The text being searched. Kept when the bar closes, so the next ⌘F starts from it.
    public var query = ""

    public init(isOpen: Bool = false, query: String = "") {
        self.isOpen = isOpen
        self.query = query
    }
}

/// Find-in-page state and actions of one browser window. Searches go through the engine's find
/// API (`BrowserTab.find` / `stopFinding`); results come back as `.findResultChanged` into the
/// tab's live state.
@MainActor
public final class FindBarModel: ObservableObject {
    /// Per model tab id.
    @Published public private(set) var states: [UUID: FindBarState] = [:]
    /// Bumped by every ⌘F so the bar's text field takes keyboard focus again (and selects its text).
    @Published public private(set) var focusRequest = 0
    /// The last `focusRequest` a bar's field acted on. A bar view that is rebuilt (tab switch,
    /// Library and back) must not take the keyboard again for a request already served (B19).
    private var servedFocusRequest = 0

    /// Whether a ⌘F is waiting for a field to take the keyboard; marks it served.
    func consumeFocusRequest() -> Bool {
        guard servedFocusRequest != focusRequest else { return false }
        servedFocusRequest = focusRequest
        return true
    }

    private let sidebar: SidebarViewModel
    /// Results live in the tab's live state; the bar redraws when it changes.
    private var sidebarChanges: AnyCancellable?

    init(sidebar: SidebarViewModel) {
        self.sidebar = sidebar
        sidebarChanges = sidebar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The tab the bar acts on: the selected tab (the focused pane in a split).
    public var targetTabID: UUID? { sidebar.selectedTabID }

    public func state(for tabID: UUID) -> FindBarState { states[tabID] ?? FindBarState() }

    /// Whether the bar shows over `tabID`'s page: open for that tab and the tab is the target.
    public func isVisible(for tabID: UUID?) -> Bool {
        guard let tabID, tabID == targetTabID else { return false }
        return state(for: tabID).isOpen
    }

    /// The selected tab has an open bar.
    public var isVisible: Bool { isVisible(for: targetTabID) }

    /// The latest engine result for `tabID`'s current search; nil while nothing is searched.
    public func result(for tabID: UUID) -> FindResult? {
        let state = state(for: tabID)
        guard state.isOpen, !state.query.isEmpty else { return nil }
        return sidebar.liveState(for: tabID)?.findResult
    }

    /// "n of m" for the bar (our wording); nil while there is no result to show.
    public func statusText(for tabID: UUID) -> String? {
        result(for: tabID).map(Self.statusText)
    }

    static func statusText(_ result: FindResult) -> String {
        "\(result.activeOrdinal) of \(result.matches)"
    }

    // MARK: Actions

    /// Edit ▸ Find ▸ Find… (⌘F): opens the bar over the target tab and focuses its field. A kept
    /// query is searched again, so its highlights come back.
    public func show() {
        guard let tabID = targetTabID else { return }
        pruneClosedTabs()
        var state = state(for: tabID)
        let wasOpen = state.isOpen
        state.isOpen = true
        states[tabID] = state
        focusRequest += 1
        if !wasOpen, !state.query.isEmpty {
            search(state.query, in: tabID, options: FindOptions())
        }
    }

    /// The bar's text changed: a new search, or the end of the search for an empty text.
    public func updateQuery(_ text: String) {
        guard let tabID = targetTabID else { return }
        var state = state(for: tabID)
        guard state.query != text else { return }
        state.query = text
        states[tabID] = state
        if text.isEmpty {
            stop(in: tabID)
        } else {
            search(text, in: tabID, options: FindOptions())
        }
    }

    /// Find Next (⌘G, or Enter in the bar). Without an open bar or a query it opens the bar.
    public func findNext() { step(backwards: false) }

    /// Find Previous (⇧⌘G, or ⇧Enter in the bar).
    public func findPrevious() { step(backwards: true) }

    /// Escape: closes the bar and clears the highlights. The query is kept for the next ⌘F.
    public func close() {
        guard let tabID = targetTabID else { return }
        close(tabID)
    }

    /// Closes `tabID`'s bar (also used when it is not the selected tab).
    public func close(_ tabID: UUID) {
        guard var state = states[tabID], state.isOpen else { return }
        state.isOpen = false
        states[tabID] = state
        stop(in: tabID)
    }

    /// Edit ▸ Find ▸ Use Selection to Find: the page's selection becomes the query (no key in [02]).
    public func useSelectionToFind() {
        guard let tabID = targetTabID else { return }
        let sidebar = self.sidebar
        sidebar.controller.enqueueEngineWork { [weak self] in
            guard let live = sidebar.liveTab(for: tabID) else { return }
            let selection = await live.selectedText()
            guard let self, !selection.isEmpty, self.targetTabID == tabID else { return }
            var state = self.state(for: tabID)
            state.isOpen = true
            state.query = selection
            self.states[tabID] = state
            self.focusRequest += 1
            self.search(selection, in: tabID, options: FindOptions())
        }
    }

    // MARK: Engine

    private func step(backwards: Bool) {
        guard let tabID = targetTabID else { return }
        let state = state(for: tabID)
        guard state.isOpen, !state.query.isEmpty else {
            show()
            return
        }
        search(state.query, in: tabID, options: FindOptions(backwards: backwards, findNext: true))
    }

    private func search(_ text: String, in tabID: UUID, options: FindOptions) {
        let sidebar = self.sidebar
        sidebar.controller.enqueueEngineWork {
            guard let live = sidebar.liveTab(for: tabID) else { return }
            await live.find(text, options: options)
        }
    }

    /// Ends the search in the engine (highlights go away) and forgets the shown result.
    private func stop(in tabID: UUID) {
        let sidebar = self.sidebar
        sidebar.controller.clearFindResult(tabID)
        sidebar.controller.enqueueEngineWork {
            guard let live = sidebar.liveTab(for: tabID) else { return }
            await live.stopFinding(keepSelection: false)
            // A result that arrived after the stop was asked for must not linger.
            sidebar.controller.clearFindResult(tabID)
        }
    }

    /// Drops the states of tabs that no longer exist.
    private func pruneClosedTabs() {
        let workspace = sidebar.workspace
        states = states.filter { workspace.tabs[$0.key].map { !$0.meta.isTombstone } ?? false }
    }
}
