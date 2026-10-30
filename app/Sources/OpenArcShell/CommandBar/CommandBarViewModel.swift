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
        didSet { queryTextDidChange(from: oldValue) }
    }
    @Published public private(set) var results: [CommandBarResult] = [] {
        didSet { if results != oldValue { missingIconsRequester?(results) } }
    }
    @Published public private(set) var selectedIndex: Int = 0
    @Published public private(set) var mode: CommandBarMode
    /// Increments whenever the field should select its whole text (⌘L prefill).
    @Published public private(set) var selectAllRequestID: Int = 0
    /// Increments on every `open`: the field must take keyboard focus (B26). The view serves the
    /// request once its field is in a window, so typing goes in without a click.
    @Published public private(set) var focusRequestID: Int = 0
    /// The inline completion the field shows: the typed text plus a selected suffix (plan B128,
    /// [05 §命令栏] observed). nil unless the first row is the site it opens and that row is
    /// selected; leaving the row and pressing Backspace clear it.
    @Published public private(set) var inlineCompletion: CommandBarInlineCompletion?
    /// True after Backspace or a deletion: the completion stays away until text is added again.
    /// inferred (Arc observed only that Backspace removes it, [05 §命令栏]).
    private var isInlineCompletionSuppressed = false

    /// The text the field shows: the typed text, or the typed text plus the completed suffix.
    public var displayedText: String { inlineCompletion?.completedText ?? queryText }

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
    /// Called with every new list (plan B132): the window fetches the icons of site rows its
    /// favicon cache lacks (never visited sites) and calls `faviconsDidChange()` when one arrives.
    /// Rows keep the globe until then; typing never waits for it.
    public var missingIconsRequester: (([CommandBarResult]) -> Void)?
    /// Bumped when an icon arrived, so the rows and the field's glyph redraw (plan B132).
    @Published public private(set) var faviconRevision = 0

    /// An icon the rows may show arrived (plan B132).
    public func faviconsDidChange() {
        faviconRevision &+= 1
    }

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
        inlineCompletion = nil
        isInlineCompletionSuppressed = false
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
        inlineCompletion = nil
        isInlineCompletionSuppressed = false
        setTextProgrammatically("")
        isPrefillUnedited = false
    }

    // MARK: Results

    /// The text sources and ranking see: empty while the prefill is unedited.
    public var effectiveQuery: String { isPrefillUnedited ? "" : queryText }

    public var selectedResult: CommandBarResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Recomputes results for the current text. Results of a superseded query are discarded, and
    /// cancelling the calling task (the next keystroke does) cancels every source's work.
    /// Deferred sources (search suggestions over the network, plan B66) do not hold up the list:
    /// the other rows are published first, then the list is ranked again with the deferred rows
    /// merged in, keeping the selected row when it is still there (inferred).
    public func refresh() async {
        generation &+= 1
        let ticket = generation
        let context = makeContext()
        let immediate = sources.enumerated().filter { !$0.element.isDeferred }
        let deferred = sources.enumerated().filter { $0.element.isDeferred }
        let first = await Self.collect(immediate, context: context)
        guard ticket == generation, !Task.isCancelled else { return }
        results = CommandBarRanker.rank(first.flatMap(\.1), context: context, limit: maxResults)
        resultsQuery = context.text
        selectedIndex = defaultSelectedIndex()
        updateInlineCompletion()
        guard !deferred.isEmpty, !context.trimmedText.isEmpty else { return }
        let late = await Self.collect(deferred, context: context)
        guard ticket == generation, !Task.isCancelled, late.contains(where: { !$0.1.isEmpty }) else { return }
        let all = (first + late).sorted { $0.0 < $1.0 }.flatMap(\.1)
        let selectedID = selectedResult?.id
        results = CommandBarRanker.rank(all, context: context, limit: maxResults)
        selectedIndex = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? defaultSelectedIndex()
        if selectedIndex == 0 { selectedIndex = defaultSelectedIndex() }
        updateInlineCompletion()
    }

    /// The row selected when a list arrives: the first one ([05 §command bar] observed), except
    /// that a completing site row whose completion was taken back (Backspace or a deletion) gives
    /// way to the plain search row, so the selected row matches what the field shows. inferred.
    private func defaultSelectedIndex() -> Int {
        guard isInlineCompletionSuppressed, results.first?.kind == .siteCompletion,
              let search = results.firstIndex(where: { $0.kind == .webSearch || $0.kind == .typedURL }) else { return 0 }
        return search
    }

    /// Recomputes the inline completion from the current text, selection and list (pure rules in
    /// `CommandBarSiteCompletionRules.inlineCompletion`). Called whenever any of them changes.
    private func updateInlineCompletion() {
        guard !isPrefillUnedited, !isInlineCompletionSuppressed, resultsAreFresh else {
            // A completion carried over a keystroke stays until the new list arrives.
            if !resultsAreFresh, !isInlineCompletionSuppressed, selectedIndex == 0 { return }
            inlineCompletion = nil
            return
        }
        inlineCompletion = CommandBarSiteCompletionRules.inlineCompletion(
            text: queryText,
            selectedIndex: selectedIndex,
            results: results
        )
    }

    /// Runs sources concurrently; answers (source index, rows) pairs sorted by index.
    private nonisolated static func collect(
        _ sources: [(offset: Int, element: any CommandBarSource)],
        context: CommandBarQueryContext
    ) async -> [(Int, [CommandBarResult])] {
        await withTaskGroup(of: (Int, [CommandBarResult]).self) { group in
            for (index, source) in sources {
                group.addTask { (index, await source.results(for: context)) }
            }
            var collected: [(Int, [CommandBarResult])] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }
        }
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

    private func queryTextDidChange(from oldText: String) {
        guard !isSettingTextProgrammatically else { return }
        isPrefillUnedited = false
        selectedIndex = 0
        // Deleting never brings a completion back; typing does. inferred.
        isInlineCompletionSuppressed = queryText.count < oldText.count
        inlineCompletion = isInlineCompletionSuppressed ? nil : CommandBarSiteCompletionRules.carriedCompletion(inlineCompletion, typed: queryText)
        scheduleRefresh()
    }

    /// Makes the inline completion part of the typed text (→ or End in the field). inferred.
    public func acceptInlineCompletion() {
        guard let completion = inlineCompletion else { return }
        queryText = completion.completedText
    }

    private func setTextProgrammatically(_ text: String) {
        isSettingTextProgrammatically = true
        queryText = text
        isSettingTextProgrammatically = false
    }

    private var resultsAreFresh: Bool { resultsQuery == effectiveQuery }

    // MARK: Keyboard

    /// Moves the selection by `delta` rows, wrapping around (inferred). The inline completion
    /// follows the first row, so moving off it clears it. [05 §命令栏] observed.
    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        updateInlineCompletion()
    }

    /// Selects a row (mouse click / tests).
    public func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        updateInlineCompletion()
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
        case .deleteBackward:
            // Backspace removes the completion ([05 §命令栏] observed, B128). With a completion up
            // the key only drops it (the field shows the typed text again); otherwise the field
            // deletes as usual and the shorter text keeps completions away.
            guard inlineCompletion != nil else { return .ignored }
            isInlineCompletionSuppressed = true
            inlineCompletion = nil
            // The completion shows exactly while the site row is selected ([05 §命令栏] observed
            // with ↓), so the field reading the typed text selects the plain search row, and
            // Return searches what is in the field. inferred.
            selectedIndex = defaultSelectedIndex()
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
        // Return with a completion up opens the completed site even before the list caught up
        // with the last keystroke. [05 §命令栏] observed (Return opens the site), B128.
        if let completion = inlineCompletion, let row = results.first(where: { $0.id == completion.resultID }) {
            return row.action
        }
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
