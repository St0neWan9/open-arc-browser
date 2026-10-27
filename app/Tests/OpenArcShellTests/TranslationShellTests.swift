import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B47: the shell's translation surfaces. docs/arc-spec/06-flows.md §19, observed unless
/// noted: a second URL box line "Translation Available" / "Translated" (19.1, 19.4), the offer
/// bubble (19.2), the Options menu (19.3), the "Translated back to …" notice with ⌘Z (19.5), the
/// toolbar's "Translation Options" button (19.1); [03 §Advanced] "Reset Translated-site Prompts".
@MainActor
final class TranslationShellTests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private let german = TranslationLanguage(code: "de", name: "German")

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.webToolbar.isShown = false
        model.stop()
        model = nil
        engine = nil
    }

    private func openGermanPage() async throws -> (UUID, FakeTab) {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "http://localhost:8747/")))
        let id = try XCTUnwrap(opened)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        live.simulatePageLanguage(german)
        try await waitUntil { self.model.translation.entryLabel(for: id) != nil }
        return (id, live)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: [06 §19.1, §19.4] the entry

    func testEntryLabelFollowsTheState() {
        XCTAssertNil(TranslationEntryLabel.make(.unavailable))
        XCTAssertEqual(TranslationEntryLabel.make(PageTranslation(status: .available))?.text, "Translation Available")
        // No progress UI: still "Translation Available" while translating. [06 §19.4] observed.
        XCTAssertEqual(TranslationEntryLabel.make(PageTranslation(status: .translating))?.text, "Translation Available")
        XCTAssertEqual(TranslationEntryLabel.make(PageTranslation(status: .translated))?.text, "Translated")
        XCTAssertEqual(TranslationEntryLabel.make(PageTranslation(status: .failed(.network)))?.text, "Translation Available")
    }

    // MARK: [06 §19.2, §19.4] bubble texts

    func testBubbleTexts() {
        let english = TranslationLanguage(code: "en", name: "English")
        let offer = TranslationBubbleContent.make(PageTranslation(status: .available, sourceLanguage: german, targetLanguage: english))
        XCTAssertEqual(offer?.title, "Translate this page to English?")
        XCTAssertEqual(offer?.primaryButton, "Translate")
        XCTAssertNil(offer?.failureNote)
        let done = TranslationBubbleContent.make(PageTranslation(status: .translated, sourceLanguage: german, targetLanguage: english))
        XCTAssertEqual(done?.title, "Translated from German.")
        XCTAssertEqual(done?.primaryButton, "Use Original")
        XCTAssertNotNil(TranslationBubbleContent.make(PageTranslation(status: .failed(.network)))?.failureNote)
        XCTAssertNil(TranslationBubbleContent.make(.unavailable))
    }

    // MARK: Flow

    /// [06 §19.2] the entry opens the bubble; [06 §19.4] Translate closes it and the page ends
    /// translated; [06 §19.5] Use Original reverts and shows the notice; ⌘Z translates again.
    func testTranslateUseOriginalAndUndo() async throws {
        let (id, live) = try await openGermanPage()
        let translation = model.translation
        XCTAssertEqual(translation.entryLabel(for: id), .available)
        translation.toggleBubble(for: id)
        XCTAssertTrue(translation.isBubblePresented(for: id))

        translation.primaryAction(for: id)
        XCTAssertFalse(translation.isBubblePresented(for: id), "the bubble closes at once")
        try await waitUntil { translation.entryLabel(for: id) == .translated }

        translation.toggleBubble(for: id)
        XCTAssertEqual(translation.bubbleContent(for: id)?.primaryButton, "Use Original")
        translation.primaryAction(for: id)
        try await waitUntil { translation.entryLabel(for: id) == .available }
        let notice = try XCTUnwrap(translation.revertNotice)
        XCTAssertEqual(notice.leadingText, "Translated back to German! Use")
        XCTAssertEqual(notice.trailingText, "to undo.")

        XCTAssertTrue(translation.undoRevert())
        XCTAssertNil(translation.revertNotice)
        try await waitUntil { translation.entryLabel(for: id) == .translated }
        XCTAssertEqual(live.commands.filter { if case .translate = $0 { true } else { false } }.count, 2)
        XCTAssertFalse(translation.undoRevert(), "⌘Z does nothing once the notice is gone")
    }

    /// [06 §19.5] observed: the notice goes away after ≈ 4 s.
    func testRevertNoticeExpires() async throws {
        let (id, _) = try await openGermanPage()
        let translation = model.translation
        translation.noticeDuration = 0.05
        translation.translate(id, to: nil)
        try await waitUntil { translation.entryLabel(for: id) == .translated }
        translation.useOriginal(id)
        XCTAssertNotNil(translation.revertNotice)
        try await waitUntil { translation.revertNotice == nil }
        XCTAssertEqual(TranslationLocalTokens.revertNoticeDuration, 3.8, accuracy: 0.2)
    }

    /// [06 §19.2] observed: Escape / a click outside close the bubble without remembering anything.
    func testClosingTheBubbleRemembersNothing() async throws {
        let (id, live) = try await openGermanPage()
        model.translation.toggleBubble(for: id)
        model.translation.closeBubble()
        XCTAssertFalse(model.translation.isBubblePresented(for: id))
        XCTAssertTrue(live.commands.isEmpty)
        XCTAssertEqual(model.translation.entryLabel(for: id), .available)
    }

    /// [06 §19.3] observed items and order; "Choose Another Language ▸" lists the engine's
    /// languages and translates into the chosen one; "Never Translate This Site" removes the entry.
    func testOptionsMenu() async throws {
        let (id, live) = try await openGermanPage()
        let translation = model.translation
        translation.toggleBubble(for: id)
        await translation.settleLanguages()
        XCTAssertEqual(TranslationOptionsMenu.titles, ["Choose Another Language", "Never Translate This Site", "", "Language Settings"])
        let languages = translation.targetLanguages.map(\.name)
        XCTAssertEqual(languages, languages.sorted())
        XCTAssertTrue(languages.contains("French"))

        // "Choose Another Language ▸ French".
        translation.translate(id, to: "fr")
        try await waitUntil { translation.translation(for: id).targetLanguage?.code == "fr" }

        translation.neverTranslateSite(id)
        try await waitUntil { translation.entryLabel(for: id) == nil }
        XCTAssertEqual(live.commands.last, .neverTranslateSite)
    }

    /// The Site Control Center has no translation entry. [06 §19.1] observed.
    func testSiteControlCenterHasNoTranslationRow() async throws {
        _ = try await openGermanPage()
        model.siteControls.present()
        XCTAssertFalse(model.siteControls.settingRows.contains { $0.title.localizedCaseInsensitiveContains("transl") })
    }

    // MARK: [06 §19.1] toolbar

    /// With the toolbar on, "Translation Options" sits left of the site controls, only while the
    /// page offers translation; spacing 36 like the other trailing buttons.
    func testToolbarButtonLeftOfSiteControls() async throws {
        model.webToolbar.isShown = true
        XCTAssertEqual(model.webToolbarItems(role: .page).trailing, [.siteControls, .splitMenu])
        _ = try await openGermanPage()
        let items = model.webToolbarItems(role: .page)
        XCTAssertEqual(items.trailing, [.translate, .siteControls, .splitMenu])
        let layout = WebToolbarLayout(barFrame: CGRect(x: 0, y: 0, width: 1000, height: 32), items: items,
                                      domainTextWidth: 80, showsInsecureLock: false)
        let translate = try XCTUnwrap(layout.frame(of: .translate))
        let siteControls = try XCTUnwrap(layout.frame(of: .siteControls))
        XCTAssertEqual(translate.size, CGSize(width: 32, height: 24))
        XCTAssertEqual(siteControls.minX - translate.minX, 36, accuracy: 0.001)
    }

    // MARK: [03 §Advanced] Reset Translated-site Prompts

    func testResetButtonClearsEveryProfilesDecisions() async {
        let settings = SettingsModel(shell: model)
        XCTAssertTrue(SettingsCatalog.control("advanced.resetTranslatePrompts").isEnabled)
        await settings.resetTranslatedSitePrompts()
        let profiles = Set(model.controller.workspace.profiles.values.filter { !$0.meta.isTombstone }.map(\.id))
        XCTAssertFalse(profiles.isEmpty)
        XCTAssertEqual(Set(engine.fakeTranslationService.resetProfileIDs), profiles)
    }
}
