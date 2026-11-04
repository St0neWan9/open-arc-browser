import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B161: the prompts a page triggers look and answer like Arc's. Acceptance: [06 §30] observed
/// (E36): the password card, the system alert sheets and the permission bubble. Marked inferred where
/// the spec has no capture: the update wording, the address / card offers, the toolbar anchor, the
/// other permission kinds.
@MainActor
final class WebPromptsB161Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var center: DialogCenter { model.controller.dialogs }
    private let localOrigin = SiteOrigin(scheme: "http", host: "127.0.0.1", port: 8765)

    private func openPage(_ address: String) async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
        let id = try XCTUnwrap(opened)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func head(of live: FakeTab, is id: UUID) async throws -> EngineDialogRequest {
        try await waitUntil { self.center.current(for: live.id)?.id == id }
        return try XCTUnwrap(center.current(for: live.id))
    }

    private func passwordRequest(kind: PasswordSavePrompt.Kind = .save) -> EngineDialogRequest {
        .passwordSave(PasswordSavePrompt(id: UUID(), origin: localOrigin, kind: kind, username: "ada", passwordLength: 4,
                                         reply: DialogReply(default: .dismiss) { _ in }))
    }

    private func javaScriptRequest(_ kind: JavaScriptDialog.Kind, defaultText: String = "", suppress: Bool = false) -> EngineDialogRequest {
        .javaScript(JavaScriptDialog(id: UUID(), origin: localOrigin, kind: kind, message: "Probe message", defaultPromptText: defaultText,
                                     showsSuppressOption: suppress, reply: DialogReply(default: .dismissed) { _ in }))
    }

    private func permissionRequest(_ kinds: [SitePermissionKind], origin: SiteOrigin?) -> EngineDialogRequest {
        .permission(PermissionPrompt(id: UUID(), origin: origin, kinds: kinds, reply: DialogReply(default: .dismiss) { _ in }))
    }

    // MARK: Password card

    /// [06 §30] observed: the exact strings; the title has the host without its port.
    func testPasswordCardTexts_06_30() {
        let presentation = DialogPresentation(passwordRequest())
        XCTAssertEqual(presentation.style, .saveCard)
        XCTAssertEqual(presentation.title, "Save password for 127.0.0.1?")
        XCTAssertEqual(presentation.message, "That way, it’ll be auto-filled next time")
        XCTAssertEqual(presentation.symbol, "key.fill")
        XCTAssertEqual(presentation.fields, [], "no username or password line")
        XCTAssertEqual(presentation.buttons, ["Never on this site", "No", "Save"])
    }

    /// [06 §30] observed: 450 × 273, the Delete Space card's size; Never alone at the left, No with
    /// ESC and the primary Save with ↵ at the right.
    func testPasswordCardLayoutAndKeys_06_30() {
        let plan = PageSaveCardPlan(DialogPresentation(passwordRequest()))
        XCTAssertEqual(plan.size, Size2D(width: 450, height: 273))
        XCTAssertEqual(plan.leading, .init(title: "Never on this site", index: 0, role: .plain))
        XCTAssertEqual(plan.trailing, [.init(title: "No", index: 1, role: .cancel), .init(title: "Save", index: 2, role: .primary)])
    }

    /// [06 §30] observed colors of the card.
    func testPasswordCardColors_06_30() {
        let t = PageSaveCardTokens.self
        XCTAssertEqual(t.iconBlockFill, RGBAColor(hex: 0xE9E9F1))
        XCTAssertEqual(t.titleInk, RGBAColor(hex: 0x14151B))
        XCTAssertEqual(t.subtitleInk, RGBAColor(hex: 0x505361))
        XCTAssertEqual(t.primaryFill, RGBAColor(hex: 0x3752F3))
        XCTAssertEqual(CGFloat(Metrics.Dialog.appIconSize), 62)
    }

    /// [06 §30] observed buttons; each reaches its engine answer. Esc presses No: `.decline`.
    func testPasswordCardRouting_06_30() async throws {
        let live = try await openPage("https://login.example")
        let id = live.simulatePasswordSavePrompt(username: "ada")
        let request = try await head(of: live, is: id)
        let plan = PageSaveCardPlan(DialogPresentation(request))
        func answer(_ button: PageSaveCardPlan.Button?) throws -> DialogAnswer {
            DialogPresentation.answer(for: request, button: try XCTUnwrap(button).index, fieldValues: [], checkbox: false)
        }
        XCTAssertEqual(try answer(plan.leading), .passwordSave(.neverForThisSite))
        XCTAssertEqual(try answer(plan.trailing.first { $0.role == .cancel }), .passwordSave(.decline))
        XCTAssertEqual(try answer(plan.trailing.first { $0.role == .primary }), .passwordSave(.save(username: nil)))
    }

    /// inferred: an update has the save layout without Never (the engine has no such answer there).
    func testUpdatePasswordCard_06_30() {
        let presentation = DialogPresentation(passwordRequest(kind: .update))
        XCTAssertEqual(presentation.title, "Update password for 127.0.0.1?")
        XCTAssertEqual(presentation.message, "That way, it’ll be auto-filled next time")
        let plan = PageSaveCardPlan(presentation)
        XCTAssertNil(plan.leading)
        XCTAssertEqual(plan.trailing, [.init(title: "No", index: 0, role: .cancel), .init(title: "Update", index: 1, role: .primary)])
    }

    /// inferred: the C30 offers use the same card, with their own icon and no Never.
    func testAddressAndCardOffersUseTheCard_06_30() async throws {
        let live = try await openPage("https://shop.example")
        let address = FakeAddress(name: "Ada Lovelace", street: "12 Example Street", city: "Springfield", postalCode: "12345")
        let addressID = try XCTUnwrap(live.simulateAddressSubmission(address))
        var request = try await head(of: live, is: addressID)
        XCTAssertEqual(DialogPresentation(request).style, .saveCard)
        XCTAssertEqual(DialogPresentation(request).symbol, "mappin.and.ellipse")
        XCTAssertNil(PageSaveCardPlan(DialogPresentation(request)).leading)
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false), .addressSave(.decline))
        center.answer(addressID, with: .addressSave(.decline))

        let card = FakeCard(number: "4111111111111111", expirationMonth: 4, expirationYear: 2031, cardholderName: "Ada Lovelace")
        let cardID = try XCTUnwrap(live.simulateCardSubmission(card))
        request = try await head(of: live, is: cardID)
        XCTAssertEqual(DialogPresentation(request).style, .saveCard)
        XCTAssertEqual(DialogPresentation(request).symbol, "creditcard.fill")
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false), .cardSave(.save))
    }

    /// inferred: an offer with more lines than the card's room makes it taller, up to a limit.
    func testLongOffersGrowTheCard_06_30() {
        func plan(lines: Int) -> PageSaveCardPlan {
            var presentation = DialogPresentation(passwordRequest())
            presentation.message = (0..<lines).map(String.init).joined(separator: "\n")
            return PageSaveCardPlan(presentation)
        }
        XCTAssertEqual(plan(lines: 3).size.height, 273)
        XCTAssertEqual(plan(lines: 5).size.height, 273 + 2 * Typography.dialogBody.lineHeight)
        XCTAssertEqual(plan(lines: 9).messageLines.count, PageSaveCardTokens.maximumLines)
    }

    private static var lastSummaries: [WindowModalSummary] = []

    private func declaredCards(for live: FakeTab) -> [WindowModalSummary] {
        Self.lastSummaries = []
        let host = NSHostingView(rootView: TabDialogOverlay(center: center, tabID: live.id, windowDrawnPermissionTab: nil)
            .frame(width: 800, height: 600)
            .onPreferenceChange(WindowModalSummaryKey.self) { summaries in
                MainActor.assumeIsolated { WebPromptsB161Tests.lastSummaries = summaries }
            })
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        return Self.lastSummaries
    }

    /// [06 §30] observed: a window card, not a panel card. The tab's overlay declares it, so it shows
    /// only while the tab is on screen and the request stays queued otherwise (inferred).
    func testOverlayDeclaresTheWindowCard_06_30() async throws {
        let live = try await openPage("https://login.example")
        XCTAssertEqual(declaredCards(for: live), [])
        let id = live.simulatePasswordSavePrompt(username: "ada")
        _ = try await head(of: live, is: id)
        XCTAssertEqual(declaredCards(for: live), [WindowModalSummary(id: "pageSaveOffer.\(id.uuidString)", size: Size2D(width: 450, height: 273))])
        center.answer(id, with: .passwordSave(.decline))
        XCTAssertEqual(declaredCards(for: live), [])
    }

    /// [06 §30]: centered in the window, like the cards of [07 §12] observed.
    func testCardIsCenteredInTheWindow_06_30() {
        let frame = WindowModalLayout.cardFrame(windowSize: CGSize(width: 1281, height: 801), cardSize: CGSize(width: 450, height: 273))
        XCTAssertEqual(frame.origin, CGPoint(x: 416, y: 264))
    }

    // MARK: JavaScript alerts

    /// [06 §30] observed: "<origin> says" (host and port), the message, the system alert.
    func testJavaScriptDialogsAreSystemAlerts_06_30() {
        for kind in [JavaScriptDialog.Kind.alert, .confirm, .prompt] {
            let presentation = DialogPresentation(javaScriptRequest(kind))
            XCTAssertEqual(presentation.style, .systemAlert)
            XCTAssertEqual(presentation.title, "127.0.0.1:8765 says")
            XCTAssertEqual(presentation.message, "Probe message")
        }
        XCTAssertEqual(DialogPresentation(javaScriptRequest(.beforeUnload)).style, .systemAlert, "inferred")
    }

    /// [06 §30] observed: Cancel at the left, OK at the right. Return presses OK, Esc Cancel.
    func testConfirmAlertButtonsAndKeys_06_30() throws {
        let content = SystemAlertContent(DialogPresentation(javaScriptRequest(.confirm)))
        let alert = content.makeAlert()
        XCTAssertEqual(alert.messageText, "127.0.0.1:8765 says")
        XCTAssertEqual(alert.informativeText, "Probe message")
        // NSAlert lists its buttons from the right.
        XCTAssertEqual(alert.buttons.map(\.title), ["OK", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertNil(alert.accessoryView)
        XCTAssertEqual(content.buttonIndex(for: .alertFirstButtonReturn), 1, "OK")
        XCTAssertEqual(content.buttonIndex(for: .alertSecondButtonReturn), 0, "Cancel")
    }

    func testAlertHasOneButton_06_30() {
        let content = SystemAlertContent(DialogPresentation(javaScriptRequest(.alert)))
        let alert = content.makeAlert()
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
        XCTAssertEqual(content.buttonIndex(for: .alertFirstButtonReturn), 0)
    }

    /// [06 §30] observed: a text field between the message and the buttons, with the default text.
    func testPromptAlertHasAField_06_30() throws {
        let alert = SystemAlertContent(DialogPresentation(javaScriptRequest(.prompt, defaultText: "default"))).makeAlert()
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        XCTAssertEqual(field.stringValue, "default")
        XCTAssertEqual(field.frame.width, SystemAlertTokens.promptFieldWidth)
        XCTAssertIdentical(alert.window.initialFirstResponder, field)
    }

    func testSuppressionCheckbox() {
        let alert = SystemAlertContent(DialogPresentation(javaScriptRequest(.alert, suppress: true))).makeAlert()
        XCTAssertTrue(alert.showsSuppressionButton)
        XCTAssertEqual(alert.suppressionButton?.title, "Prevent this page from creating additional dialogs")
    }

    /// The button that ended the sheet reaches the engine, the field's text and the checkbox with it.
    func testAlertAnswersReachTheEngine_06_30() async throws {
        let live = try await openPage("https://dialogs.example")
        let prompt = live.simulateJavaScriptDialog(.prompt, message: "Name?", defaultPromptText: "Ada")
        var request = try await head(of: live, is: prompt)
        var controller = SystemAlertController(center: center, request: request)
        var alert = SystemAlertContent(DialogPresentation(request)).makeAlert()
        (alert.accessoryView as? NSTextField)?.stringValue = "Grace"
        controller.finish(.alertFirstButtonReturn, alert: alert)
        XCTAssertEqual(live.dialogAnswers[prompt], .javaScript(JavaScriptDialogReply(accepted: true, promptText: "Grace")))

        let confirm = live.simulateJavaScriptDialog(.confirm, message: "Sure?")
        request = try await head(of: live, is: confirm)
        controller = SystemAlertController(center: center, request: request)
        alert = SystemAlertContent(DialogPresentation(request)).makeAlert()
        controller.finish(.alertSecondButtonReturn, alert: alert)
        XCTAssertEqual(live.dialogAnswers[confirm], .javaScript(JavaScriptDialogReply(accepted: false)))
        XCTAssertNil(center.current(for: live.id))
    }

    /// One dialog at a time per tab, and a sheet closed because its tab left the screen answers
    /// nothing: the request stays queued for when the tab returns. inferred.
    func testClosedSheetLeavesTheRequestQueued_06_30() async throws {
        let live = try await openPage("https://dialogs.example")
        let first = live.simulateJavaScriptDialog(.alert, message: "1")
        let second = live.simulateJavaScriptDialog(.alert, message: "2")
        let request = try await head(of: live, is: first)
        try await waitUntil { self.center.pendingCount(for: live.id) == 2 }

        let controller = SystemAlertController(center: center, request: request)
        let alert = SystemAlertContent(DialogPresentation(request)).makeAlert()
        controller.finish(.abort, alert: alert)
        XCTAssertEqual(center.current(for: live.id)?.id, first, "no button: no answer")
        controller.close()
        controller.finish(.alertFirstButtonReturn, alert: alert)
        XCTAssertEqual(center.current(for: live.id)?.id, first, "closed: no answer")
        XCTAssertNil(live.dialogAnswers[first])

        center.answer(first, with: .javaScript(JavaScriptDialogReply(accepted: true)))
        XCTAssertEqual(center.current(for: live.id)?.id, second, "the next one shows after the first is answered")
    }

    // MARK: Permission bubble

    /// [06 §30] observed strings: the full origin, with scheme and port.
    func testPermissionTexts_06_30() {
        XCTAssertEqual(PermissionPromptText.sentence(origin: localOrigin, kinds: [.location]),
                       "Allow http://127.0.0.1:8765 to access your location?")
        XCTAssertEqual(PermissionPromptText.sentence(origin: localOrigin, kinds: [.notifications]),
                       "Allow http://127.0.0.1:8765 to send you notifications?")
    }

    /// inferred: the same form for the kinds without a capture.
    func testOtherPermissionKinds_06_30() {
        XCTAssertEqual(PermissionPromptText.phrase(for: [.camera]), "use your camera")
        XCTAssertEqual(PermissionPromptText.phrase(for: [.microphone]), "use your microphone")
        XCTAssertEqual(PermissionPromptText.phrase(for: [.camera, .microphone]), "use your camera and microphone")
        XCTAssertEqual(PermissionPromptText.phrase(for: [.location, .notifications]), "access your location and send you notifications")
        XCTAssertEqual(PermissionPromptText.phrase(for: [.camera, .microphone, .location]), "use your camera and microphone and access your location")
        XCTAssertEqual(PermissionPromptText.sentence(origin: nil, kinds: [.camera]), "Allow this page to use your camera?")
        for kind in SitePermissionKind.allCases {
            XCTAssertFalse(kind.promptPhrase.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: kind.promptSymbol, accessibilityDescription: nil), kind.promptSymbol)
        }
    }

    /// [06 §30] observed: SF icons for location and notifications; camera and microphone as asked.
    func testPermissionIcons_06_30() {
        XCTAssertEqual(SitePermissionKind.location.promptSymbol, "location.fill")
        XCTAssertEqual(SitePermissionKind.notifications.promptSymbol, "bell.fill")
        XCTAssertEqual(SitePermissionKind.camera.promptSymbol, "camera.fill")
        XCTAssertEqual(SitePermissionKind.microphone.promptSymbol, "mic.fill")
        XCTAssertEqual(DialogPresentation(permissionRequest([.camera, .microphone], origin: localOrigin)).symbol, "camera.fill")
    }

    /// [06 §30] observed: two buttons, Not Now then Allow, whatever the engine supports.
    func testPermissionButtons_06_30() {
        for once in [true, false] {
            let request = EngineDialogRequest.permission(PermissionPrompt(
                id: UUID(), origin: localOrigin, kinds: [.location], supportsAllowingOnce: once,
                reply: DialogReply(default: .dismiss) { _ in }))
            let presentation = DialogPresentation(request)
            XCTAssertEqual(presentation.style, .permissionBubble)
            XCTAssertEqual(presentation.buttons, ["Not Now", "Allow"])
            XCTAssertEqual(presentation.title, "")
        }
    }

    /// [06 §30] observed: bubble width and colors; it is the theme's tint with an arrow to the button.
    func testPermissionBubbleChrome_06_30() throws {
        let t = PermissionPromptTokens.self
        XCTAssertEqual(t.width, 236, "the 262 pt window less its 13 pt inset each side")
        XCTAssertEqual(t.notNowFill, RGBAColor(hex: 0xDAD8E4))
        XCTAssertEqual(t.textInk, RGBAColor(hex: 0x5D5D65))
        XCTAssertEqual(t.text.size, 14, "the spec's ≈ 13; the capture's ink widths fit 14")

        let palette = ThemeDerivation.palette(for: nil as Theme?)
        let bubble = permissionPromptBubbleRequest(nil, palette: palette)
        XCTAssertEqual(bubble.style.width, t.width)
        XCTAssertNil(bubble.style.height, "the text may wrap: measured")
        XCTAssertEqual(bubble.style.tint, palette.floatingPanelBackground)
        XCTAssertFalse(bubble.style.becomesKey)
        XCTAssertTrue(bubble.waitsForAnswer)
        guard case .attached(.below) = bubble.placement else { return XCTFail("hangs from the button") }
    }

    /// [06 §30] observed Not Now and Allow; Esc = Not Now as asked. Not Now stores nothing (inferred),
    /// Allow stores the grant, and a click outside or a switch to another app answers nothing.
    func testPermissionRouting_06_30() async throws {
        let live = try await openPage("https://maps.example")
        let palette = ThemeDerivation.palette(for: nil as Theme?)

        let first = live.simulatePermissionPrompt([.location])
        _ = try await head(of: live, is: first)
        var prompt = try XCTUnwrap(center.permissionPrompt(for: live.id))
        prompt.press(PendingPermissionPrompt.allowIndex)
        XCTAssertEqual(live.dialogAnswers[first], .permission(.allow(remember: true)))

        let second = live.simulatePermissionPrompt([.notifications])
        _ = try await head(of: live, is: second)
        prompt = try XCTUnwrap(center.permissionPrompt(for: live.id))
        prompt.press(PendingPermissionPrompt.notNowIndex)
        XCTAssertEqual(live.dialogAnswers[second], .permission(.dismiss))

        let third = live.simulatePermissionPrompt([.camera])
        _ = try await head(of: live, is: third)
        let bubble = permissionPromptBubbleRequest(center.permissionPrompt(for: live.id), palette: palette)
        bubble.onDismiss(.clickOutside)
        bubble.onDismiss(.appDeactivated)
        bubble.onDismiss(.windowClosed)
        XCTAssertNil(live.dialogAnswers[third])
        XCTAssertEqual(center.current(for: live.id)?.id, third)
        bubble.onDismiss(.escape)
        XCTAssertEqual(live.dialogAnswers[third], .permission(.dismiss))
    }

    /// `permissionPrompt(for:)` finds a permission at the head of the queue only.
    func testPermissionPromptLookup_06_30() async throws {
        let live = try await openPage("https://maps.example")
        XCTAssertNil(center.permissionPrompt(for: nil))
        XCTAssertNil(center.permissionPrompt(for: live.id))
        let alert = live.simulateJavaScriptDialog(.alert, message: "Hi")
        let permission = live.simulatePermissionPrompt([.location])
        _ = try await head(of: live, is: alert)
        try await waitUntil { self.center.pendingCount(for: live.id) == 2 }
        XCTAssertNil(center.permissionPrompt(for: live.id), "one dialog at a time")
        center.answer(alert, with: .javaScript(JavaScriptDialogReply(accepted: true)))
        XCTAssertEqual(center.permissionPrompt(for: live.id)?.request.id, permission)
    }

    /// [06 §30] observed the URL box's button; the toolbar's inferred. Other tabs have no button:
    /// their panel draws the bubble.
    func testPermissionBubblePlacement_06_30() {
        let tab = UUID(), other = UUID()
        typealias P = PermissionPromptPlacement
        XCTAssertTrue(P.isAtSiteControls(tabID: tab, selectedTabID: tab, hasURLBoxControls: true, isToolbarShown: false))
        XCTAssertTrue(P.isAtSiteControls(tabID: tab, selectedTabID: tab, hasURLBoxControls: false, isToolbarShown: true))
        XCTAssertFalse(P.isAtSiteControls(tabID: tab, selectedTabID: tab, hasURLBoxControls: false, isToolbarShown: false))
        XCTAssertFalse(P.isAtSiteControls(tabID: other, selectedTabID: tab, hasURLBoxControls: true, isToolbarShown: true))
        XCTAssertFalse(P.isAtSiteControls(tabID: nil, selectedTabID: nil, hasURLBoxControls: true, isToolbarShown: false))
    }

    /// [07 §12] observed for the same button: centered below it, 12 pt away, arrow on the top edge.
    func testBubbleHangsBelowTheButton_06_30() {
        let anchor = CGRect(x: 234, y: 49, width: 30, height: 30)
        let frame = FloatingBubbleLayout.attached(anchor: anchor, side: .below, size: CGSize(width: 236, height: 118),
                                                  container: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                                  cornerRadius: PermissionPromptTokens.cornerRadius)
        XCTAssertEqual(frame.bubble.minY, anchor.maxY + 12)
        XCTAssertEqual(frame.bubble.midX, anchor.midX)
        XCTAssertEqual(frame.arrow?.edge, .top)
    }
}
