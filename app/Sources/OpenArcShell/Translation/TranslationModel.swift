import Foundation
import Combine
import OpenArcEngine
import OpenArcDesign

// State and intents of page translation in a window (plan B47). The engine decides and translates
// (`BrowserTab.translate(to:)`, `PageTranslation`); this model draws Arc's surfaces. Spec:
// docs/arc-spec/06-flows.md §19, observed unless noted:
// - 19.1 No translate bar, no automatic bubble. The URL box gains a second line, "Translation
//   Available", under the domain; with the toolbar on a "Translation Options" icon button sits left
//   of the Site Control Center button instead. The Site Control Center has no translation entry.
// - 19.2 Clicking the entry opens a bubble: "Translate this page to <target>?" with "Options" and
//   "Translate". Escape or a click outside closes it without remembering anything.
// - 19.3 "Options" is a native menu at the pointer: "Choose Another Language ▸" (every target
//   language), "Never Translate This Site", a separator, "Language Settings".
// - 19.4 "Translate" closes the bubble; no progress UI (the line stays "Translation Available"),
//   then the line reads "Translated". Its bubble: "Translated from <source>." with "Options" and
//   "Use Original".
// - 19.5 "Use Original" reverts and shows "Translated back to <source>! Use ⌘Z to undo." at the
//   web panel's top right for ≈ 3.6–4 s; ⌘Z meanwhile translates again.

/// What the URL box's second line (or the toolbar button's help) says. [06 §19.1, §19.4] observed.
enum TranslationEntryLabel: Equatable {
    case available
    case translated

    var text: String {
        switch self {
        case .available: "Translation Available"
        case .translated: "Translated"
        }
    }

    /// [06 §19.4] observed: the line stays "Translation Available" while translating. A failed
    /// attempt keeps the offer (inferred; failure UI not captured, [06 §19.6]).
    static func make(_ translation: PageTranslation) -> TranslationEntryLabel? {
        switch translation.status {
        case .unavailable: nil
        case .available, .translating, .failed: .available
        case .translated: .translated
        }
    }
}

/// The bubble's content. [06 §19.2, §19.4] observed texts.
struct TranslationBubbleContent: Equatable {
    var title: String
    /// The primary (right) button.
    var primaryButton: String
    /// A line under the title when the last attempt failed. Our wording: unknown ([06 §19.6]).
    var failureNote: String?

    static func make(_ translation: PageTranslation) -> TranslationBubbleContent? {
        switch translation.status {
        case .unavailable:
            return nil
        case .translated:
            let source = translation.sourceLanguage?.name ?? "the original language"
            return TranslationBubbleContent(title: "Translated from \(source).", primaryButton: "Use Original")
        case .available, .translating, .failed:
            let target = translation.targetLanguage?.name ?? "your language"
            var content = TranslationBubbleContent(title: "Translate this page to \(target)?", primaryButton: "Translate")
            if case .failed(let failure) = translation.status { content.failureNote = failure.note }
            return content
        }
    }
}

extension TranslationFailure {
    /// One line in the offer bubble after a failure. Our wording: unknown ([06 §19.6] not captured).
    var note: String {
        switch self {
        case .network: "Couldn’t reach the translation service. Check your connection and try again."
        case .serviceUnavailable: "The translation service isn’t available right now."
        case .unknownLanguage: "The page’s language couldn’t be detected."
        case .unsupportedLanguage: "This language can’t be translated."
        case .identicalLanguages: "This page is already in that language."
        case .translationFailed: "The page couldn’t be translated. Try again."
        }
    }
}

/// The "Translated back to <source>! Use ⌘Z to undo." notice. [06 §19.5] observed.
struct TranslationRevertNotice: Equatable {
    /// The model tab that was reverted (⌘Z translates it again).
    var tabID: UUID
    var sourceName: String
    /// The language it was translated into, for the undo.
    var targetCode: String?

    /// Text before and after the ⌘Z key cap.
    var leadingText: String { "Translated back to \(sourceName)! Use" }
    var trailingText: String { "to undo." }
}

@MainActor
public final class TranslationModel: ObservableObject {
    /// The tab whose bubble is open, if any.
    @Published private(set) var bubbleTabID: UUID?
    @Published private(set) var revertNotice: TranslationRevertNotice?
    /// Target languages for "Choose Another Language ▸", loaded once from the engine.
    @Published private(set) var targetLanguages: [TranslationLanguage] = []

    /// [06 §19.5] observed: the notice disappears after ≈ 3.6–4 s (AX gone at the 13th 0.4 s
    /// sample). 3.8 s inferred (middle of the observed range).
    var noticeDuration: Double = TranslationLocalTokens.revertNoticeDuration

    private let sidebar: SidebarViewModel
    private let engine: any EngineTranslation
    /// Opens a URL in a new tab ("Language Settings").
    var openURL: (URL) -> Void = { _ in }
    private var noticeTask: Task<Void, Never>?
    private var languagesTask: Task<Void, Never>?
    private var selectionChanges: AnyCancellable?
    private var sidebarChanges: AnyCancellable?

    init(sidebar: SidebarViewModel, engine: any EngineTranslation) {
        self.sidebar = sidebar
        self.engine = engine
        // A bubble belongs to its tab: switching tabs closes it (inferred, like the Site Control
        // Center).
        selectionChanges = sidebar.$selectedTabID.dropFirst().sink { [weak self] newID in
            guard let self, let open = self.bubbleTabID, open != newID else { return }
            self.closeBubble()
        }
        // The entry and the bubble read the tab's live translation state from the sidebar.
        sidebarChanges = sidebar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Derived state

    func translation(for tabID: UUID?) -> PageTranslation {
        tabID.flatMap { sidebar.liveState(for: $0)?.translation } ?? .unavailable
    }

    /// The URL box line / toolbar button for a tab; nil hides it.
    func entryLabel(for tabID: UUID?) -> TranslationEntryLabel? {
        TranslationEntryLabel.make(translation(for: tabID))
    }

    func bubbleContent(for tabID: UUID?) -> TranslationBubbleContent? {
        TranslationBubbleContent.make(translation(for: tabID))
    }

    func isBubblePresented(for tabID: UUID?) -> Bool {
        tabID != nil && bubbleTabID == tabID && bubbleContent(for: tabID) != nil
    }

    // MARK: Intents

    /// Click on "Translation Available" / "Translated" or the toolbar button: toggles the bubble.
    func toggleBubble(for tabID: UUID?) {
        guard let tabID, entryLabel(for: tabID) != nil else { return }
        if bubbleTabID == tabID {
            closeBubble()
        } else {
            bubbleTabID = tabID
            loadLanguagesIfNeeded()
        }
    }

    /// Escape, a click outside, or an action. Nothing is remembered. [06 §19.2] observed.
    func closeBubble() {
        bubbleTabID = nil
    }

    /// The bubble's primary button: "Translate" (and retry after a failure) or "Use Original".
    func primaryAction(for tabID: UUID?) {
        guard let tabID else { return }
        switch translation(for: tabID).status {
        case .translated:
            useOriginal(tabID)
        case .available, .failed:
            translate(tabID, to: nil)
        case .translating, .unavailable:
            closeBubble()
        }
    }

    /// "Translate" (or a language from "Choose Another Language ▸"): the bubble closes at once.
    /// [06 §19.4] observed.
    func translate(_ tabID: UUID, to languageCode: String?) {
        closeBubble()
        dismissRevertNotice()
        guard let live = sidebar.liveTab(for: tabID) else { return }
        Task { await live.translate(to: languageCode) }
    }

    /// "Use Original": reverts and shows the undo notice. [06 §19.5] observed.
    func useOriginal(_ tabID: UUID) {
        let state = translation(for: tabID)
        closeBubble()
        guard let live = sidebar.liveTab(for: tabID) else { return }
        Task { await live.revertTranslation() }
        guard state.status == .translated else { return }
        showRevertNotice(TranslationRevertNotice(
            tabID: tabID, sourceName: state.sourceLanguage?.name ?? "the original language",
            targetCode: state.targetLanguage?.code
        ))
    }

    /// "Never Translate This Site". [06 §19.3] observed item; its effect ([06 §19.6] not captured)
    /// is the engine's: the site goes on the profile's never-translate list and the entry goes away.
    func neverTranslateSite(_ tabID: UUID) {
        closeBubble()
        guard let live = sidebar.liveTab(for: tabID) else { return }
        Task { await live.neverTranslateSite() }
    }

    /// "Language Settings": the engine's language settings page in a new tab. [06 §19.3] inferred
    /// ("opens the engine's language settings page; not clicked").
    func openLanguageSettings() {
        closeBubble()
        if let url = URL(string: "chrome://settings/languages") { openURL(url) }
    }

    /// ⌘Z while the notice shows: translate again. [06 §19.5] observed. Returns whether it acted
    /// (the Edit menu's Undo falls through to the page otherwise).
    @discardableResult
    func undoRevert() -> Bool {
        guard let notice = revertNotice else { return false }
        dismissRevertNotice()
        guard let live = sidebar.liveTab(for: notice.tabID) else { return false }
        Task { await live.translate(to: notice.targetCode) }
        return true
    }

    var canUndoRevert: Bool { revertNotice != nil }

    func dismissRevertNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        revertNotice = nil
    }

    func stop() {
        noticeTask?.cancel()
        languagesTask?.cancel()
        selectionChanges = nil
        sidebarChanges = nil
    }

    // MARK: Internals

    private func showRevertNotice(_ notice: TranslationRevertNotice) {
        noticeTask?.cancel()
        revertNotice = notice
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.revertNotice = nil
        }
    }

    private func loadLanguagesIfNeeded() {
        guard targetLanguages.isEmpty, languagesTask == nil else { return }
        let engine = engine
        languagesTask = Task { [weak self] in
            let languages = await engine.targetLanguages()
            guard let self else { return }
            self.targetLanguages = languages
            self.languagesTask = nil
        }
    }

    /// Waits for the language list (tests).
    func settleLanguages() async {
        await languagesTask?.value
    }
}
