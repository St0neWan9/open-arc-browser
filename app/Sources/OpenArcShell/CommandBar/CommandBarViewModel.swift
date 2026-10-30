import Foundation
import Combine

// Observable state of the command bar. No UI types, so keyboard behavior and routing are
// unit-testable. The caller owns execution: `activate` only returns a typed `CommandBarAction`.
//
// Keyboard behavior:
//   observed  [05 §command bar] the first row is selected by default; Escape closes.
//   observed  [05 §命令栏] E30: Tab enters a site search while the field offers one ("Search
//             YouTube Tab"); Backspace after an inline completion keeps the site row first.
//   inferred  Up/Down wrap around; Shift-Tab = Up; without a site search on offer Tab puts the
//             selected row's completion text into the field; Enter before fresh results exist
//             acts on the raw text.

@MainActor
public final class CommandBarViewModel: ObservableObject {
    /// Maximum rows kept after ranking. unknown (only the five-row panel was measured); inferred 8.
    public static let defaultMaxResults = 8

    /// Text of the field. Setting it (typing) refreshes the results.
    @Published public var queryText: String = "" {
        didSet { queryTextDidChange(from: oldValue) }
    }
    @Published public private(set) var results: [CommandBarResult] = [] {
        didSet { if results != oldValue { requestMissingIcons() } }
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
    /// True after Backspace or a deletion: the completion stays away until text is added again,
    /// and the completing site row shows as "host — host" with a globe. [05 §命令栏] E30 observed
    /// for Backspace; the same for further deletions is inferred.
    private var isInlineCompletionSuppressed = false

    /// The site the field searches after Tab ("Tab to Search", plan B133): the field shows the
    /// site's chip and the "Search…" placeholder, and lists no rows. [05 §命令栏] E30 observed.
    @Published public private(set) var siteSearch: CommandBarSearchSite?
    /// The sites the field can offer for "Tab to Search" (built-in list, inferred; see
    /// `CommandBarSearchSites`).
    public var searchSites: [CommandBarSearchSite] = CommandBarSearchSites.builtIn

    /// The site the field's right-hand hint offers ("Search YouTube Tab"), nil for none: never
    /// during a site search or over the unedited ⌘L prefill. [05 §命令栏] E30 observed hint.
    public var siteSearchOffer: CommandBarSearchSite? {
        guard siteSearch == nil, !isPrefillUnedited else { return nil }
        let completedHost = inlineCompletion.flatMap { completion in
            results.first { $0.id == completion.resultID }?.url.flatMap(CommandBarTextNormalizer.host)
        }
        return CommandBarSearchSites.match(typed: queryText, completedHost: completedHost, sites: searchSites)
    }

    /// The site of the profile's default search engine, whose icon the field's glyph shows while
    /// one character is typed (plan B133, [05 §命令栏] E30 observed Google's "G"). Installed by
    /// the window; nil keeps the magnifier.
    public var searchEngineSite: (() -> URL?)?

    /// A site row standing for the search engine's icon: what `faviconProvider` and the icon
    /// loader take. Never listed.
    public var searchEngineIconRow: CommandBarResult? {
        guard let url = searchEngineSite?() else { return nil }
        return CommandBarResult(
            id: "search-engine:\(url.absoluteString)",
            kind: .siteSuggestion,
            title: url.host ?? url.absoluteString,
            url: url,
            iconHint: .site(faviconURL: nil),
            actionLabel: nil,
            action: .openURL(url, target: .newTab)
        )
    }

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

    /// Asks the window for the icons the rows and the field's glyph may show (plan B132, B133).
    private func requestMissingIcons() {
        guard let requester = missingIconsRequester else { return }
        requester(results + (searchEngineIconRow.map { [$0] } ?? []))
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
        siteSearch = nil
        setTextProgrammatically("")
        isPrefillUnedited = false
        requestMissingIcons()
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
        siteSearch = nil
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
        guard ticket == generation, !Task.isCancelled, siteSearch == nil else { return }
        results = presented(CommandBarRanker.rank(first.flatMap(\.1), context: context, limit: maxResults))
        resultsQuery = context.text
        selectedIndex = 0
        updateInlineCompletion()
        guard !deferred.isEmpty, !context.trimmedText.isEmpty else { return }
        let late = await Self.collect(deferred, context: context)
        guard ticket == generation, !Task.isCancelled, siteSearch == nil,
              late.contains(where: { !$0.1.isEmpty }) else { return }
        let all = (first + late).sorted { $0.0 < $1.0 }.flatMap(\.1)
        let selectedID = selectedResult?.id
        results = presented(CommandBarRanker.rank(all, context: context, limit: maxResults))
        selectedIndex = selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        updateInlineCompletion()
    }

    /// The ranked list as shown: after Backspace took the completion back, the completing site row
    /// stays first and selected, as "host — host" with a globe. [05 §命令栏] E30 observed
    /// ("youtube.com — youtube.com", globe, not the search row).
    private func presented(_ ranked: [CommandBarResult]) -> [CommandBarResult] {
        guard isInlineCompletionSuppressed, let first = ranked.first, first.kind == .siteCompletion else { return ranked }
        var list = ranked
        list[0] = CommandBarSiteCompletionRules.takenBackRow(first)
        return list
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
        // A site search lists no rows. [05 §命令栏] E30 observed.
        guard siteSearch == nil else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func queryTextDidChange(from oldText: String) {
        guard !isSettingTextProgrammatically else { return }
        isPrefillUnedited = false
        selectedIndex = 0
        // A site search only collects the query. [05 §命令栏] E30 observed: no rows.
        guard siteSearch == nil else { return }
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
            // Backspace on the empty field of a site search leaves the site search (plan B133,
            // inferred: the field stays empty and lists the empty-query rows again).
            if siteSearch != nil {
                guard queryText.isEmpty else { return .ignored }
                leaveSiteSearch()
                return .handled
            }
            // Backspace removes the completion ([05 §命令栏] observed, B128). With a completion up
            // the key only drops it (the field shows the typed text again); otherwise the field
            // deletes as usual and the shorter text keeps completions away.
            guard inlineCompletion != nil else { return .ignored }
            isInlineCompletionSuppressed = true
            inlineCompletion = nil
            // The site row stays first and selected, as "host — host" with a globe, so Return
            // still opens the site. [05 §命令栏] E30 observed (plan B133).
            results = presented(results)
            selectedIndex = 0
            return .handled
        case .tab:
            // "Tab to Search": with a site on offer, Tab turns the field into that site's search.
            // [05 §命令栏] E30 observed.
            if let site = siteSearchOffer {
                enterSiteSearch(site)
                return .handled
            }
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

    // MARK: Site search

    /// Turns the field into a search of `site`: empty field, no rows. [05 §命令栏] E30 observed.
    public func enterSiteSearch(_ site: CommandBarSearchSite) {
        refreshTask?.cancel()
        generation &+= 1
        siteSearch = site
        inlineCompletion = nil
        isInlineCompletionSuppressed = false
        isPrefillUnedited = false
        setTextProgrammatically("")
        results = []
        resultsQuery = nil
        selectedIndex = 0
    }

    /// Back to the plain bar, listing the rows for what the field holds. inferred.
    public func leaveSiteSearch() {
        guard siteSearch != nil else { return }
        siteSearch = nil
        scheduleRefresh()
    }

    // MARK: Activation

    /// The action for the selected row (or `index`). When the results are older than the typed
    /// text, Enter must still do what the text says, so the raw text is classified instead:
    /// URL → open it, otherwise search. Returns nil if there is nothing to do.
    public func activate(at index: Int? = nil) -> CommandBarAction? {
        // Return in a site search opens the site's results for the typed query. [05 §命令栏] E30
        // (the search itself is inferred from Chrome's keyword search). Nothing for an empty query.
        if let site = siteSearch {
            return site.searchURL(for: queryText).map { .openURL($0, target: mode.openTarget) }
        }
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
