import Foundation
import Combine

// Observable state of the command bar. No UI types, so keyboard behavior and routing are
// unit-testable. The caller owns execution: `activate` only returns a typed `CommandBarAction`.
//
// Keyboard behavior:
//   observed  [05 §command bar] the first row is selected by default; Escape closes.
//   inferred  Up/Down wrap around; Shift-Tab = Up; Tab puts the selected row's completion text
//             into the field; Enter before fresh results exist acts on the raw text.
//   unknown   what Tab really does in the original.

@MainActor
public final class CommandBarViewModel: ObservableObject {
    /// Maximum rows kept after ranking. unknown (only the five-row panel was measured); inferred 8.
    public static let defaultMaxResults = 8

    /// Text of the field. Setting it (typing) refreshes the results.
    @Published public var queryText: String = "" {
        didSet { queryTextDidChange() }
    }
    @Published public private(set) var results: [CommandBarResult] = []
    @Published public private(set) var selectedIndex: Int = 0
    @Published public private(set) var mode: CommandBarMode
    /// Increments whenever the field should select its whole text (⌘L prefill).
    @Published public private(set) var selectAllRequestID: Int = 0
    /// Increments on every `open`: the field must take keyboard focus (B26). The view serves the
    /// request once its field is in a window, so typing goes in without a click.
    @Published public private(set) var focusRequestID: Int = 0

    public let presentation: CommandBarPresentation
    public var sources: [any CommandBarSource]
    public let maxResults: Int

    /// Called by `handle(_:)`/`activate` consumers (the view) when an action must run.
    public var onAction: ((CommandBarAction) -> Void)?
    /// Called when the bar must close.
    public var onDismiss: (() -> Void)?
    /// PNG bytes of a site row's favicon (C9): installed by the window from its favicon cache;
    /// nil (or a nil result) keeps the placeholder glyph.
    public var faviconProvider: ((CommandBarResult) -> Data?)?

    public private(set) var currentSpaceID: UUID?
    public private(set) var currentTabID: UUID?
    /// An empty query lists only the help commands (the incognito window's bar). [06 §20.1]
    /// observed (B61).
    public var listsHelpOnlyWhenEmpty = false

    /// True while the field shows the unedited prefill from `open(mode: .currentTab, …)`. The result
    /// list then behaves as for an empty query (inferred; otherwise the viewed tab would match itself).
    public private(set) var isPrefillUnedited = false

    private var isSettingTextProgrammatically = false
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    /// Query text the current `results` were computed for.
    private var resultsQuery: String?

    public init(
        sources: [any CommandBarSource],
        mode: CommandBarMode = .newTab,
        presentation: CommandBarPresentation = .window,
        currentSpaceID: UUID? = nil,
        currentTabID: UUID? = nil,
        maxResults: Int = CommandBarViewModel.defaultMaxResults
    ) {
        self.sources = sources
        self.mode = mode
        self.presentation = presentation
        self.currentSpaceID = currentSpaceID
        self.currentTabID = currentTabID
        self.maxResults = maxResults
    }

    // MARK: Opening and closing

    /// Resets the bar for a new use.
    /// - ⌘T (`.newTab`): empty field. [02] observed.
    /// - ⌘L (`.currentTab`): the field holds the current address, fully selected. [02] "edit the
    ///   current address" observed; selecting it all is inferred.
    public func open(mode: CommandBarMode, currentURL: URL? = nil, currentTabID: UUID? = nil, currentSpaceID: UUID? = nil) {
        refreshTask?.cancel()
        self.mode = mode
        self.currentTabID = currentTabID
        self.currentSpaceID = currentSpaceID
        results = []
        resultsQuery = nil
        selectedIndex = 0
        setTextProgrammatically("")
        isPrefillUnedited = false
        if mode == .currentTab, let currentURL {
            setTextProgrammatically(currentURL.absoluteString)
            isPrefillUnedited = true
            selectAllRequestID += 1
        }
        focusRequestID += 1
        scheduleRefresh()
    }

    /// Stops pending work and clears the list.
    public func dismiss() {
        refreshTask?.cancel()
        generation &+= 1
        results = []
        resultsQuery = nil
        selectedIndex = 0
        setTextProgrammatically("")
        isPrefillUnedited = false
    }

    // MARK: Results

    /// The text sources and ranking see: empty while the prefill is unedited.
    public var effectiveQuery: String { isPrefillUnedited ? "" : queryText }

    public var selectedResult: CommandBarResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Recomputes results for the current text. Results of a superseded query are discarded.
    public func refresh() async {
        generation &+= 1
        let ticket = generation
        let context = makeContext()
        let sources = self.sources
        let candidates: [CommandBarResult] = await withTaskGroup(of: (Int, [CommandBarResult]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { (index, await source.results(for: context)) }
            }
            var collected: [(Int, [CommandBarResult])] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        guard ticket == generation, !Task.isCancelled else { return }
        results = CommandBarRanker.rank(candidates, context: context, limit: maxResults)
        resultsQuery = context.text
        selectedIndex = 0
    }

    /// Waits for the refresh started by the latest text change (for tests).
    public func waitForRefresh() async {
        await refreshTask?.value
    }

    private func makeContext() -> CommandBarQueryContext {
        CommandBarQueryContext(
            text: effectiveQuery,
            mode: mode,
            presentation: presentation,
            currentSpaceID: currentSpaceID,
            currentTabID: currentTabID,
            listsHelpOnlyWhenEmpty: listsHelpOnlyWhenEmpty
        )
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func queryTextDidChange() {
        guard !isSettingTextProgrammatically else { return }
        isPrefillUnedited = false
        selectedIndex = 0
        scheduleRefresh()
    }

    private func setTextProgrammatically(_ text: String) {
        isSettingTextProgrammatically = true
        queryText = text
        isSettingTextProgrammatically = false
    }

    private var resultsAreFresh: Bool { resultsQuery == effectiveQuery }

    // MARK: Keyboard

    /// Moves the selection by `delta` rows, wrapping around (inferred).
    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    /// Selects a row (mouse click / tests).
    public func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Feeds a key. Also notifies `onAction` / `onDismiss`.
    @discardableResult
    public func handle(_ key: CommandBarKey) -> CommandBarKeyOutcome {
        switch key {
        case .up, .shiftTab:
            moveSelection(by: -1)
            return .handled
        case .down:
            moveSelection(by: 1)
            return .handled
        case .tab:
            if let selected = selectedResult, resultsAreFresh {
                queryText = selected.completion
            }
            return .handled
        case .returnKey:
            guard let action = activate() else { return .handled }
            onAction?(action)
            return .activate(action)
        case .escape:
            onDismiss?()
            return .dismiss
        }
    }

    // MARK: Activation

    /// The action for the selected row (or `index`). When the results are older than the typed
    /// text, Enter must still do what the text says, so the raw text is classified instead:
    /// URL → open it, otherwise search. Returns nil if there is nothing to do.
    public func activate(at index: Int? = nil) -> CommandBarAction? {
        if let index {
            return results.indices.contains(index) ? results[index].action : nil
        }
        if resultsAreFresh, let selected = selectedResult { return selected.action }
        return fallbackAction()
    }

    /// Action derived from the raw text alone.
    public func fallbackAction() -> CommandBarAction? {
        let target = mode.openTarget
        switch CommandBarInputClassifier.classify(effectiveQuery) {
        case .empty: return nil
        case .url(let url): return .openURL(url, target: target)
        case .search(let query): return .searchWeb(query: query, target: target)
        }
    }
}
