import Foundation
import Combine
import CoreGraphics
import OpenArcEngine
import OpenArcDesign

// Shell side of engine dialog requests (plan C7b / C12 / C13; chromium-bridge/SWIFT_PROTOCOL_CHANGES.md
// §3). The engine raises JavaScript dialogs, HTTP auth, permission prompts, file choosers,
// external-protocol prompts, password save prompts and autofill dropdowns per tab (`BrowserTab.dialogRequests()`); this queue holds them per
// tab and the views draw the head of each queue (TabDialogViews.swift).
//
// Decisions without evidence (the spec records none of these dialogs; all inferred):
// - One FIFO queue per tab: a tab shows one dialog at a time, the next one after it is answered.
// - Dialogs are tab-modal: they cover only that tab's web panel or split pane, never the window.
// - Permission prompts and the password save prompt (C13) are a bubble under the sidebar's URL box
//   when the tab is the selected tab and the sidebar shows; otherwise at the top left of the tab's
//   panel.
// - The autofill dropdown (C13) is not queued: one per tab, under its form field, beside whatever
//   dialog shows.
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
    case autofillPopup(AutofillPopupReply)
    case extensionInstall(ExtensionInstallReply)
}

/// Dialog requests of every live tab of one workspace controller, queued per engine tab.
@MainActor
public final class DialogCenter: ObservableObject {
    /// Unanswered requests per tab, oldest first.
    @Published public private(set) var queues: [EngineTabID: [EngineDialogRequest]] = [:]
    /// The autofill dropdown of each tab (C13). Not queued: it is not modal, a newer one replaces the
    /// older, and it shows alongside a queued dialog.
    @Published public private(set) var autofillPopups: [EngineTabID: AutofillPopup] = [:]

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
        case (.autofillPopup(let r), .autofillPopup(let a)): sent = r.reply.send(a)
        case (.extensionInstall(let r), .extensionInstall(let a)): sent = r.reply.send(a)
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
        queues[tabID, default: []].append(request)
    }

    private func request(_ requestID: UUID) -> EngineDialogRequest? {
        for queue in queues.values {
            if let found = queue.first(where: { $0.id == requestID }) { return found }
        }
        if let popup = autofillPopups.values.first(where: { $0.id == requestID }) { return .autofillPopup(popup) }
        return nil
    }

    private func remove(_ requestID: UUID) {
        for (tabID, popup) in autofillPopups where popup.id == requestID { autofillPopups[tabID] = nil }
        for (tabID, queue) in queues where queue.contains(where: { $0.id == requestID }) {
            let rest = queue.filter { $0.id != requestID && !$0.isFinished }
            queues[tabID] = rest.isEmpty ? nil : rest
        }
    }
}

// MARK: - Presentation

/// What a dialog shows, derived from its request. No UI types, so it is unit-testable. All texts
/// are our own wording (the spec records none of these dialogs): unknown.
public struct DialogPresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// A card attached to the top of the tab's panel, over a dimmed page.
        case sheet
        /// A bubble under the URL box (or at the panel's top left).
        case permissionBubble
        /// The system open / save panel.
        case filePanel
        /// The autofill dropdown under a form field (C13; drawn by `AutofillDropdownView`).
        case dropdown
    }

    public enum Field: Equatable, Sendable {
        case text(placeholder: String, initial: String)
        case secure(placeholder: String)
    }

    public var style: Style
    public var title: String
    public var message: String
    public var fields: [Field]
    /// Title of the "remember" / "suppress" checkbox, if the dialog has one.
    public var checkbox: String?
    /// Buttons from left to right; the last one is the default (Return).
    public var buttons: [String]

    public init(_ request: EngineDialogRequest) {
        let site = request.origin?.displayHost ?? "This page"
        switch request {
        case .javaScript(let dialog):
            fields = []
            checkbox = dialog.showsSuppressOption ? "Prevent this page from creating additional dialogs" : nil
            style = .sheet
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
            style = .permissionBubble
            title = "\(site) wants to"
            message = prompt.kinds.map(\.promptText).joined(separator: "\n")
            fields = []
            checkbox = nil
            // A one-time grant only where the engine supports it (Chromium: camera, microphone,
            // location); otherwise "Allow" is the only grant. Chromium's semantics, inferred.
            buttons = prompt.supportsAllowingOnce ? ["Don’t Allow", "Allow This Time", "Allow"] : ["Don’t Allow", "Allow"]
        case .fileChooser(let chooser):
            style = .filePanel
            title = chooser.mode == .save ? "Save" : "Open"
            message = ""
            fields = []
            checkbox = nil
            buttons = ["Cancel", chooser.mode == .save ? "Save" : "Open"]
        case .passwordSave(let prompt):
            // Chrome anchors its save bubble to the address bar; Arc's address bar is the sidebar's
            // URL box, so it hangs there like a permission prompt. Wording is Chrome's meaning in
            // our words: unknown ([00 §A] records no style).
            style = .permissionBubble
            title = prompt.kind == .update ? "Update password?" : "Save password?"
            message = "Password: " + String(repeating: "•", count: max(prompt.passwordLength, 1))
            fields = [.text(placeholder: "Username", initial: prompt.username)]
            checkbox = nil
            buttons = prompt.kind == .update ? ["Not Now", "Update"] : ["Never", "Not Now", "Save"]
        case .extensionInstall(let prompt):
            // Chrome's install dialog, tab-modal over the store page. The spec does not record the
            // Web Store flow (C14): title and buttons are Chrome's meaning in our words, unknown.
            style = .sheet
            title = "Add “\(prompt.extensionName)”?"
            message = prompt.permissionWarnings.isEmpty
                ? ""
                : "It can:\n" + prompt.permissionWarnings.map { "• " + $0 }.joined(separator: "\n")
            fields = []
            checkbox = nil
            buttons = ["Cancel", "Add Extension"]
        case .autofillPopup:
            style = .dropdown
            title = ""
            message = ""
            fields = []
            checkbox = nil
            buttons = []
        case .externalProtocol(let external):
            style = .sheet
            let app = external.handlerApplicationName ?? "the application"
            title = "Open \(external.handlerApplicationName.map { "“\($0)”" } ?? "application")?"
            message = "\(site) wants to open \(app)."
            fields = []
            checkbox = external.canRememberForOrigin
                ? request.origin.map { "Always allow \($0.displayHost) to open links of this type" } : nil
            buttons = ["Cancel", "Open"]
        }
    }

    /// The answer for button `index` (as in `buttons`), with the field values and checkbox state.
    public static func answer(for request: EngineDialogRequest, button index: Int, fieldValues: [String], checkbox: Bool) -> DialogAnswer {
        let isDefaultButton = index == DialogPresentation(request).buttons.count - 1
        switch request {
        case .javaScript(let dialog):
            let text = dialog.kind == .prompt && isDefaultButton ? (fieldValues.first ?? dialog.defaultPromptText) : nil
            // An alert's single button is its acceptance.
            return .javaScript(JavaScriptDialogReply(accepted: isDefaultButton, promptText: text, suppressFurtherDialogs: checkbox))
        case .authentication:
            guard isDefaultButton else { return .authentication(.cancel) }
            return .authentication(.proceed(username: fieldValues.first ?? "", password: fieldValues.dropFirst().first ?? ""))
        case .permission(let prompt):
            switch (index, prompt.supportsAllowingOnce) {
            case (0, _): return .permission(.deny(remember: true))
            case (1, true): return .permission(.allow(remember: false))
            default: return .permission(.allow(remember: true))
            }
        case .fileChooser:
            return .fileChooser(.cancel)
        case .externalProtocol:
            return .externalProtocol(isDefaultButton ? .open(rememberForOrigin: checkbox) : .block)
        case .passwordSave(let prompt):
            if isDefaultButton {
                let edited = fieldValues.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return .passwordSave(.save(username: edited == prompt.username ? nil : edited))
            }
            return .passwordSave(prompt.kind == .save && index == 0 ? .neverForThisSite : .decline)
        case .autofillPopup:
            return .autofillPopup(.dismiss)
        case .extensionInstall:
            return .extensionInstall(isDefaultButton ? .add : .cancel)
        }
    }
}

extension SitePermissionKind {
    /// One line of the permission bubble ("Use your camera"). Our wording: unknown.
    var promptText: String {
        switch self {
        case .camera: "Use your camera"
        case .microphone: "Use your microphone"
        case .location: "Know your location"
        case .notifications: "Show notifications"
        case .clipboardRead: "See text and images copied to the clipboard"
        case .midi: "Use your MIDI devices"
        case .storageAccess: "Use cookies and site data in this context"
        case .screenWakeLock: "Keep your screen on"
        case .multipleDownloads: "Download multiple files"
        case .localFonts: "Use the fonts on your computer"
        case .windowManagement: "Manage windows on all your displays"
        case .idleDetection: "Know when you’re actively using this device"
        case .protectedMedia: "Play protected content"
        }
    }
}

/// Where a permission bubble goes. inferred (see the file header).
enum PermissionPromptPlacement {
    /// Width of the bubble. unknown.
    static let bubbleWidth: CGFloat = 260
    /// Gap between the URL box and the bubble. unknown.
    static let gap: CGFloat = 6
    /// Inset from the panel's top left when not under the URL box. unknown.
    static let panelInset: CGFloat = 10

    /// Whether `tabID`'s permission bubble is drawn under the URL box (by the window) rather than
    /// inside the tab's panel.
    static func isUnderURLBox(tabID: UUID?, selectedTabID: UUID?, isSidebarVisible: Bool) -> Bool {
        isSidebarVisible && tabID != nil && tabID == selectedTabID
    }

    /// Top-left corner of the bubble under the URL box, in window coordinates.
    static func originUnderURLBox(in layout: MainWindowLayout) -> CGPoint {
        let box = layout.addressFieldFrame
        return CGPoint(x: box.minX, y: box.maxY + gap)
    }
}
