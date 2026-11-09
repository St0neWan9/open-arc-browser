import Foundation
import Combine
import CoreGraphics
import OpenArcEngine
import OpenArcDesign

// Shell side of engine dialog requests (plan C7b / C12 / C13; chromium-bridge/SWIFT_PROTOCOL_CHANGES.md
// §3). The engine raises JavaScript dialogs, HTTP auth, permission prompts, file choosers,
// external-protocol prompts, password / address / card save prompts, autofill dropdowns, unresponsive-page
// prompts (C22), client-certificate pickers (C25) and the WebAuthn dialog (C21) per tab (`BrowserTab.dialogRequests()`); this queue holds them per
// tab and the views draw the head of each queue (TabDialogViews.swift).
//
// Where each prompt shows ([06 §30] observed unless noted):
// - The password save / update prompt is a card centered in the window over the dimmed window, like
//   New Folder and Delete Space (`PageSaveCard`). The address / card save offers (C30) use the same
//   card: inferred.
// - JavaScript alert / confirm / prompt are system alert sheets on the window
//   (`SystemAlertPresenter`). The beforeunload prompt comes the same way: inferred.
// - Permission requests are a bubble from the site controls button of the URL box, or of the web
//   toolbar while it shows (toolbar: inferred). Without such a button (hidden sidebar, inactive
//   split pane, Peek, Little Arc) the same bubble sits at the top left of the tab's panel: inferred.
//
// Decisions without evidence (inferred):
// - One FIFO queue per tab: a tab shows one dialog at a time, the next one after it is answered.
// - A request shows only while its tab is on screen. Its card, sheet or bubble goes away with the
//   tab and comes back, still unanswered, when the tab returns.
// - The extension install confirmation is a prompt card centered in the window over the dimmed
//   window ([06 §41] observed). The other dialogs (HTTP auth, external protocol, unresponsive page,
//   certificates, passkeys) use the same card (B197, inferred); they show while their tab is on
//   screen.
// - The autofill dropdown (C13) is not queued: one per tab, under its form field, beside whatever
//   dialog shows.
// - Engine info bars (C23, [00 §A] inferred) are not queued either: every open bar of a
//   tab shows as a strip above its page, oldest on top, beside whatever dialog shows.
// - Closing the tab's page (archive, unload, window close) answers every queued request with its
//   default, like the bridge does for a released request.

/// The user's answer to a dialog, whatever its kind.
public enum DialogAnswer: Hashable, Sendable {
    case javaScript(JavaScriptDialogReply)
    case authentication(AuthenticationReply)
    case permission(PermissionReply)
    case fileChooser(FileChooserReply)
    case externalProtocol(ExternalProtocolReply)
    case passwordSave(PasswordSaveReply)
    case addressSave(AutofillSaveReply)
    case cardSave(AutofillSaveReply)
    case autofillPopup(AutofillPopupReply)
    case extensionInstall(ExtensionInstallReply)
    case unresponsivePage(UnresponsivePageReply)
    case clientCertificate(ClientCertificateReply)
    case webAuthn(WebAuthnReply)
    case infoBar(InfoBarReply)
}

/// Dialog requests of every live tab of one workspace controller, queued per engine tab.
@MainActor
public final class DialogCenter: ObservableObject {
    /// Unanswered requests per tab, oldest first.
    @Published public private(set) var queues: [EngineTabID: [EngineDialogRequest]] = [:]
    /// The autofill dropdown of each tab (C13). Not queued: it is not modal, a newer one replaces the
    /// older, and it shows alongside a queued dialog.
    @Published public private(set) var autofillPopups: [EngineTabID: AutofillPopup] = [:]
    /// The open info bars of each tab (C23), oldest first. Not queued: all of them show.
    @Published public private(set) var infoBarLists: [EngineTabID: [InfoBarRequest]] = [:]

    private var observers: [EngineTabID: [Task<Void, Never>]] = [:]

    public init() {}

    /// Starts collecting `tab`'s requests. Requests the engine raised before this call already got
    /// their defaults (no subscriber). Idempotent.
    public func observe(_ tab: any BrowserTab) {
        let id = tab.id
        guard observers[id] == nil else { return }
        let requests = tab.dialogRequests()
        let events = tab.events()
        observers[id] = [
            Task { [weak self] in
                for await request in requests {
                    guard let self else { return }
                    self.enqueue(request, on: id)
                }
            },
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    if case .dialogCancelled(let requestID) = event { self.remove(requestID) }
                }
            },
        ]
    }

    /// Stops collecting `tabID`'s requests and answers the queued ones with their defaults (the
    /// page is going away).
    public func stopObserving(_ tabID: EngineTabID) {
        observers.removeValue(forKey: tabID)?.forEach { $0.cancel() }
        let pending = queues.removeValue(forKey: tabID) ?? []
        for request in pending { request.answerWithDefault() }
        autofillPopups.removeValue(forKey: tabID)?.reply.sendDefault()
        for bar in infoBarLists.removeValue(forKey: tabID) ?? [] { bar.reply.sendDefault() }
    }

    /// The info bars `tabID` shows now, oldest first (C23).
    public func infoBars(for tabID: EngineTabID) -> [InfoBarRequest] {
        infoBarLists[tabID]?.filter { !$0.reply.isFinished } ?? []
    }

    /// The autofill dropdown `tabID` shows now (C13).
    public func autofillPopup(for tabID: EngineTabID) -> AutofillPopup? {
        guard let popup = autofillPopups[tabID], !popup.reply.isFinished else { return nil }
        return popup
    }

    /// The request `tabID` shows now: the oldest unanswered one.
    public func current(for tabID: EngineTabID) -> EngineDialogRequest? {
        queues[tabID]?.first { !$0.isFinished }
    }

    /// Number of unanswered requests of `tabID`.
    public func pendingCount(for tabID: EngineTabID) -> Int {
        queues[tabID]?.filter { !$0.isFinished }.count ?? 0
    }

    /// Answers a request and shows the tab's next one. An answer of the wrong kind is ignored.
    /// Returns whether the engine took the answer.
    @discardableResult
    public func answer(_ requestID: UUID, with answer: DialogAnswer) -> Bool {
        guard let request = request(requestID) else { return false }
        let sent: Bool
        switch (request, answer) {
        case (.javaScript(let r), .javaScript(let a)): sent = r.reply.send(a)
        case (.authentication(let r), .authentication(let a)): sent = r.reply.send(a)
        case (.permission(let r), .permission(let a)): sent = r.reply.send(a)
        case (.fileChooser(let r), .fileChooser(let a)): sent = r.reply.send(a)
        case (.externalProtocol(let r), .externalProtocol(let a)): sent = r.reply.send(a)
        case (.passwordSave(let r), .passwordSave(let a)): sent = r.reply.send(a)
        case (.addressSave(let r), .addressSave(let a)): sent = r.reply.send(a)
        case (.cardSave(let r), .cardSave(let a)): sent = r.reply.send(a)
        case (.autofillPopup(let r), .autofillPopup(let a)): sent = r.reply.send(a)
        case (.extensionInstall(let r), .extensionInstall(let a)): sent = r.reply.send(a)
        case (.unresponsivePage(let r), .unresponsivePage(let a)): sent = r.reply.send(a)
        case (.clientCertificate(let r), .clientCertificate(let a)): sent = r.reply.send(a)
        case (.webAuthn(let r), .webAuthn(let a)): sent = r.reply.send(a)
        case (.infoBar(let r), .infoBar(let a)): sent = r.reply.send(a)
        default: return false
        }
        remove(requestID)
        return sent
    }

    /// Closes a dialog without a choice (Escape, ✕): the request gets its default answer.
    public func dismiss(_ requestID: UUID) {
        request(requestID)?.answerWithDefault()
        remove(requestID)
    }

    // MARK: Internals

    private func enqueue(_ request: EngineDialogRequest, on tabID: EngineTabID) {
        // The engine may have withdrawn it already (events and requests are separate streams).
        guard !request.isFinished else { return }
        if case .autofillPopup(let popup) = request {
            autofillPopups[tabID] = popup
            return
        }
        if case .infoBar(let bar) = request {
            infoBarLists[tabID, default: []].append(bar)
            return
        }
        queues[tabID, default: []].append(request)
    }

    private func request(_ requestID: UUID) -> EngineDialogRequest? {
        for queue in queues.values {
            if let found = queue.first(where: { $0.id == requestID }) { return found }
        }
        if let popup = autofillPopups.values.first(where: { $0.id == requestID }) { return .autofillPopup(popup) }
        for bars in infoBarLists.values {
            if let bar = bars.first(where: { $0.id == requestID }) { return .infoBar(bar) }
        }
        return nil
    }

    private func remove(_ requestID: UUID) {
        for (tabID, popup) in autofillPopups where popup.id == requestID { autofillPopups[tabID] = nil }
        for (tabID, bars) in infoBarLists where bars.contains(where: { $0.id == requestID }) {
            let rest = bars.filter { $0.id != requestID && !$0.reply.isFinished }
            infoBarLists[tabID] = rest.isEmpty ? nil : rest
        }
        for (tabID, queue) in queues where queue.contains(where: { $0.id == requestID }) {
            let rest = queue.filter { $0.id != requestID && !$0.isFinished }
            queues[tabID] = rest.isEmpty ? nil : rest
        }
    }
}

// MARK: - Presentation

/// What a dialog shows, derived from its request. No UI types, so it is unit-testable. Texts are
/// [06 §30] observed where a comment says so; the rest are our own wording: unknown.
public struct DialogPresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A prompt card centered in the window over the dimmed window (`PromptCard`). [06 §41]
        /// observed for the extension install; the others inferred (B197).
        case sheet
        /// A bubble from the site controls button (or at the panel's top left). [06 §30] observed.
        case permissionBubble
        /// A card centered in the window (`PageSaveCard`). [06 §30] observed.
        case saveCard
        /// A system alert sheet on the window (`SystemAlertPresenter`). [06 §30] observed.
        case systemAlert
        /// The system open / save panel.
        case filePanel
        /// The autofill dropdown under a form field (C13; drawn by `AutofillDropdownView`).
        case dropdown
        /// The passkey / security-key card (C21; drawn by `WebAuthnSheetView` as a prompt card, its
        /// steps change while it is open).
        case webAuthn
        /// An engine info bar: a strip above the page (C23; drawn by `InfoBarStrip`).
        case infoBar
    }

    /// One row of a single-choice list (the client-certificate picker, C25).
    public struct Choice: Equatable, Sendable {
        public var title: String
        public var detail: String
    }

    public enum Field: Equatable, Sendable {
        case text(placeholder: String, initial: String)
        case secure(placeholder: String)
    }

    public var style: Style
    public var title: String
    public var message: String
    /// SF Symbol of the prompts that show one (save cards, permission bubbles).
    public var symbol: String?
    public var fields: [Field]
    /// Title of the "remember" / "suppress" checkbox, if the dialog has one.
    public var checkbox: String?
    /// Rows to choose one from (the first is selected at first); empty for most dialogs.
    public var choices: [Choice] = []
    /// A bulleted list under the message (the extension's permissions). [06 §41] observed.
    public var bullets: [String] = []
    /// Buttons from left to right; the last one is the default (Return).
    public var buttons: [String]
    /// The button Esc presses (it shows the ESC key cap): the one before the default, unless that
    /// one is not the request's default answer (then Esc closes with the default, no button).
    public var cancelButtonIndex: Int? { cancelsWithEsc && buttons.count > 1 ? buttons.count - 2 : nil }
    private var cancelsWithEsc = true

    public init(_ request: EngineDialogRequest) {
        let site = request.origin?.displayHost ?? "This page"
        switch request {
        case .javaScript(let dialog):
            fields = []
            checkbox = dialog.showsSuppressOption ? "Prevent this page from creating additional dialogs" : nil
            // "<origin> says", the message, Cancel / OK. [06 §30] observed.
            style = .systemAlert
            switch dialog.kind {
            case .alert:
                title = "\(site) says"
                message = dialog.message
                buttons = ["OK"]
            case .confirm:
                title = "\(site) says"
                message = dialog.message
                buttons = ["Cancel", "OK"]
            case .prompt:
                title = "\(site) says"
                message = dialog.message
                fields = [.text(placeholder: "", initial: dialog.defaultPromptText)]
                buttons = ["Cancel", "OK"]
            case .beforeUnload:
                title = dialog.isReload ? "Reload site?" : "Leave site?"
                message = dialog.message
                buttons = ["Cancel", dialog.isReload ? "Reload" : "Leave"]
            }
        case .authentication(let challenge):
            style = .sheet
            title = "Sign in"
            symbol = "lock.fill"
            var text = challenge.isProxy
                ? "The proxy \(challenge.challengerHostPort) requires a username and password."
                : "\(challenge.challengerHostPort) requires a username and password."
            if !challenge.realm.isEmpty { text += " Realm: “\(challenge.realm)”." }
            if challenge.isInsecureConnection { text += " Your connection to this site is not private." }
            message = text
            fields = [.text(placeholder: "Username", initial: challenge.suggestedUsername ?? ""), .secure(placeholder: "Password")]
            checkbox = nil
            buttons = ["Cancel", "Sign In"]
        case .permission(let prompt):
            // Two buttons, whatever the engine supports. [06 §30] observed.
            style = .permissionBubble
            title = ""
            message = PermissionPromptText.sentence(origin: prompt.origin, kinds: prompt.kinds)
            symbol = prompt.kinds.first?.promptSymbol
            fields = []
            checkbox = nil
            buttons = ["Not Now", "Allow"]
        case .fileChooser(let chooser):
            style = .filePanel
            title = chooser.mode == .save ? "Save" : "Open"
            message = ""
            fields = []
            checkbox = nil
            buttons = ["Cancel", chooser.mode == .save ? "Save" : "Open"]
        case .passwordSave(let prompt):
            // [06 §30] observed for the save prompt: the host without its port, no username or
            // password line. The update prompt keeps that layout, with no "Never" (the engine treats
            // it as a decline there) and our title and button: inferred.
            style = .saveCard
            let host = prompt.origin?.host ?? "this site"
            title = prompt.kind == .update ? "Update password for \(host)?" : "Save password for \(host)?"
            message = "That way, it’ll be auto-filled next time"
            symbol = "key.fill"
            fields = []
            checkbox = nil
            buttons = prompt.kind == .update ? ["No", "Update"] : ["Never on this site", "No", "Save"]
        case .addressSave(let prompt):
            // C30: the password card's layout ([06 §30] observed there). Titles, the details under
            // them and the icon are ours, inferred; the engine has no "never" for these offers.
            style = .saveCard
            if prompt.kind == .update {
                title = "Update address?"
                message = prompt.changes.map { change in
                    let label = change.field.displayName
                    return change.oldValue.isEmpty
                        ? "\(label): \(change.newValue)"
                        : "\(label): \(change.oldValue) → \(change.newValue)"
                }.joined(separator: "\n")
            } else {
                title = "Save address?"
                message = ([prompt.addressSummary, prompt.email, prompt.phone].filter { !$0.isEmpty }).joined(separator: "\n")
            }
            symbol = "mappin.and.ellipse"
            fields = []
            checkbox = nil
            buttons = ["No", prompt.kind == .update ? "Update" : "Save"]
        case .cardSave(let prompt):
            // C30: like the address offer, inferred. Saved on this Mac only (Open Arc has no Google
            // Payments).
            style = .saveCard
            title = prompt.kind == .securityCodeOnly ? "Save security code?" : "Save card?"
            let card = [prompt.network, "••••" + prompt.lastFourDigits].filter { !$0.isEmpty }.joined(separator: " ")
            var lines = [card]
            if !prompt.expiration.isEmpty { lines.append("Expires " + prompt.expiration) }
            if !prompt.cardholderName.isEmpty { lines.append(prompt.cardholderName) }
            message = lines.joined(separator: "\n")
            symbol = "creditcard.fill"
            fields = []
            checkbox = nil
            buttons = ["No", "Save"]
        case .extensionInstall(let prompt):
            // [06 §41] observed: a prompt card with the app icon ← the extension's icon, "Add the
            // “<name>” extension to <app>?", "It can:" and the permissions as bullets, Cancel ESC /
            // Add Extension ↵. Without permissions there is no "It can:": inferred.
            style = .sheet
            title = "Add the “\(prompt.extensionName)” extension to \(AppIdentity.displayName)?"
            message = prompt.permissionWarnings.isEmpty ? "" : "It can:"
            bullets = prompt.permissionWarnings
            fields = []
            checkbox = nil
            buttons = ["Cancel", "Add Extension"]
        case .unresponsivePage:
            // [00 §A] inferred: a "page unresponsive" dialog with wait or leave. Look and
            // wording are ours (unknown). Tab-modal like the other sheets; Return waits, the
            // destructive choice is never the default.
            style = .sheet
            title = "This page isn’t responding"
            message = "\(site) has stopped responding. You can wait for it, or leave the page."
            symbol = "hourglass"
            fields = []
            checkbox = nil
            buttons = ["Leave Page", "Wait"]
            // Esc waits (the default), never leaves.
            cancelsWithEsc = false
        case .clientCertificate(let prompt):
            // [00 §A] inferred: a picker for sites that ask for a certificate. Look and
            // wording are ours (unknown). Cancel continues without a certificate, as Chrome's does.
            style = .sheet
            title = "Select a certificate"
            symbol = "person.text.rectangle.fill"
            message = "\(prompt.hostPort) needs a certificate to identify you."
            fields = []
            checkbox = nil
            choices = prompt.certificates.map {
                Choice(title: $0.subjectName,
                       detail: "Issued by \($0.issuerName) · Expires \($0.validUntil.formatted(date: .abbreviated, time: .omitted))")
            }
            buttons = ["Cancel", "OK"]
        case .webAuthn(let dialog):
            // Drawn by `WebAuthnSheetView` from the session's live state (`WebAuthnPresentation`).
            let live = WebAuthnPresentation(dialog.session.state)
            style = .webAuthn
            symbol = "person.badge.key.fill"
            title = live.title
            message = live.message
            fields = []
            checkbox = nil
            buttons = ["Cancel"]
        case .autofillPopup:
            style = .dropdown
            title = ""
            message = ""
            fields = []
            checkbox = nil
            buttons = []
        case .infoBar(let bar):
            // [00 §A] inferred: engine info bars drawn by the shell above the page. The
            // texts are the engine's; buttons left to right: Cancel, then OK (the default).
            style = .infoBar
            title = ""
            message = bar.message
            fields = []
            checkbox = nil
            var titles: [String] = []
            if bar.buttons.contains(.cancel) { titles.append(bar.cancelTitle) }
            if bar.buttons.contains(.ok) { titles.append(bar.okTitle) }
            buttons = titles
        case .externalProtocol(let external):
            style = .sheet
            let app = external.handlerApplicationName ?? "the application"
            title = "Open \(external.handlerApplicationName.map { "“\($0)”" } ?? "application")?"
            message = "\(site) wants to open \(app)."
            symbol = "arrow.up.forward.app.fill"
            fields = []
            checkbox = external.canRememberForOrigin
                ? request.origin.map { "Always allow \($0.displayHost) to open links of this type" } : nil
            buttons = ["Cancel", "Open"]
        }
    }

    /// The answer for button `index` (as in `buttons`), with the field values, checkbox state and
    /// the chosen row of `choices`.
    public static func answer(
        for request: EngineDialogRequest, button index: Int, fieldValues: [String], checkbox: Bool, selection: Int? = nil
    ) -> DialogAnswer {
        let isDefaultButton = index == DialogPresentation(request).buttons.count - 1
        switch request {
        case .javaScript(let dialog):
            let text = dialog.kind == .prompt && isDefaultButton ? (fieldValues.first ?? dialog.defaultPromptText) : nil
            // An alert's single button is its acceptance.
            return .javaScript(JavaScriptDialogReply(accepted: isDefaultButton, promptText: text, suppressFurtherDialogs: checkbox))
        case .authentication:
            guard isDefaultButton else { return .authentication(.cancel) }
            return .authentication(.proceed(username: fieldValues.first ?? "", password: fieldValues.dropFirst().first ?? ""))
        case .permission:
            // "Not Now" stores no decision, so the site may ask again: inferred from its wording
            // ([06 §30] observed the button, not what Arc stores).
            return .permission(isDefaultButton ? .allow(remember: true) : .dismiss)
        case .fileChooser:
            return .fileChooser(.cancel)
        case .externalProtocol:
            return .externalProtocol(isDefaultButton ? .open(rememberForOrigin: checkbox) : .block)
        case .passwordSave(let prompt):
            // The card has no username field ([06 §30] observed): the submitted one is saved.
            if isDefaultButton { return .passwordSave(.save(username: nil)) }
            return .passwordSave(prompt.kind == .save && index == 0 ? .neverForThisSite : .decline)
        case .addressSave:
            return .addressSave(isDefaultButton ? .save : .decline)
        case .cardSave:
            return .cardSave(isDefaultButton ? .save : .decline)
        case .autofillPopup:
            return .autofillPopup(.dismiss)
        case .extensionInstall:
            return .extensionInstall(isDefaultButton ? .add : .cancel)
        case .unresponsivePage:
            return .unresponsivePage(isDefaultButton ? .wait : .leave)
        case .clientCertificate(let prompt):
            guard isDefaultButton, !prompt.certificates.isEmpty else { return .clientCertificate(.continueWithout) }
            let chosen = min(max(selection ?? 0, 0), prompt.certificates.count - 1)
            return .clientCertificate(.select(index: chosen))
        case .webAuthn:
            return .webAuthn(.cancel)
        case .infoBar(let bar):
            // Buttons as in `buttons`: Cancel (when there is one) first, OK last.
            let isCancel = bar.buttons.contains(.cancel) && index == 0
            return .infoBar(isCancel || !bar.buttons.contains(.ok) ? .decline : .accept)
        }
    }
}

extension AddressSavePrompt.Change.Field {
    /// Row label of an update prompt. Our wording: unknown.
    var displayName: String {
        switch self {
        case .name: "Name"
        case .address: "Address"
        case .email: "Email"
        case .phone: "Phone"
        }
    }
}

extension SiteOrigin {
    /// Scheme, host and port, as the permission bubble spells a site. [06 §30] observed.
    var fullText: String { "\(scheme)://\(displayHost)" }
}

extension SitePermissionKind {
    /// The verb phrase of the permission bubble. [06 §30] observed for location and notifications;
    /// the others are our wording in the same form: inferred.
    var promptPhrase: String {
        switch self {
        case .location: "access your location"
        case .notifications: "send you notifications"
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .clipboardRead: "see text and images copied to the clipboard"
        case .midi: "use your MIDI devices"
        case .storageAccess: "use cookies and site data in this context"
        case .screenWakeLock: "keep your screen on"
        case .multipleDownloads: "download multiple files"
        case .localFonts: "use the fonts on your computer"
        case .windowManagement: "manage windows on all your displays"
        case .idleDetection: "know when you’re actively using this device"
        case .protectedMedia: "play protected content"
        }
    }

    /// SF Symbol of the permission bubble. [06 §30] observed for location and notifications; the
    /// others inferred.
    var promptSymbol: String {
        switch self {
        case .location: "location.fill"
        case .notifications: "bell.fill"
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .clipboardRead: "doc.on.clipboard.fill"
        case .midi: "pianokeys"
        case .storageAccess: "externaldrive.fill"
        case .screenWakeLock: "sun.max.fill"
        case .multipleDownloads: "arrow.down.circle.fill"
        case .localFonts: "textformat"
        case .windowManagement: "macwindow.on.rectangle"
        case .idleDetection: "person.fill"
        case .protectedMedia: "play.rectangle.fill"
        }
    }
}

/// The body text of the permission bubble.
enum PermissionPromptText {
    /// "Allow <origin> to <verb phrase>?". [06 §30] observed: the full origin, with scheme and port.
    /// The wording without an origin is ours: inferred.
    static func sentence(origin: SiteOrigin?, kinds: [SitePermissionKind]) -> String {
        "Allow \(origin?.fullText ?? "this page") to \(phrase(for: kinds))?"
    }

    /// One phrase for a request of several kinds: camera and microphone share theirs, the others are
    /// listed. inferred (the spec records single kinds).
    static func phrase(for kinds: [SitePermissionKind]) -> String {
        let sharesCamera = kinds.contains(.camera) && kinds.contains(.microphone)
        let phrases = kinds.compactMap { kind -> String? in
            guard sharesCamera else { return kind.promptPhrase }
            switch kind {
            case .camera: return "use your camera and microphone"
            case .microphone: return nil
            default: return kind.promptPhrase
            }
        }
        guard let last = phrases.last, phrases.count > 1 else { return phrases.first ?? "" }
        return phrases.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Where a permission bubble goes.
enum PermissionPromptPlacement {
    /// Inset from the panel's top left when no site controls button is there to point at. unknown.
    static let panelInset: CGFloat = 10

    /// Whether `tabID`'s bubble hangs from a site controls button rather than sitting in the tab's
    /// panel. Only the selected tab has that button: the URL box belongs to it, and with the toolbar
    /// on it is the active pane, the only one whose bar carries the button. [06 §30] observed the URL
    /// box; the toolbar's button inferred.
    static func isAtSiteControls(tabID: UUID?, selectedTabID: UUID?, hasURLBoxControls: Bool, isToolbarShown: Bool) -> Bool {
        (hasURLBoxControls || isToolbarShown) && tabID != nil && tabID == selectedTabID
    }
}
