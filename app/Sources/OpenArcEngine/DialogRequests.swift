import Foundation
import os

// Dialogs and prompts the shell draws itself (plan C12; chromium-bridge/SWIFT_PROTOCOL_CHANGES.md
// §3; bridge: OACDialogDelegate.h). The engine decides WHEN to ask (Chromium's suppression rules,
// permission manager, login handler, external protocol policy); the shell only draws and answers.
//
// Contract, matching the bridge:
// - Every request carries a `DialogReply` that accepts exactly one answer; later answers are
//   ignored (`send` returns false).
// - Dropping the last copy of an unanswered request answers it with its default (alert:
//   dismissed, confirm/prompt/beforeunload: cancel, permission: dismissed (not remembered),
//   auth: cancel, file chooser: cancel, external protocol: block), so a page never hangs.
// - The engine may withdraw an unanswered request (navigation, the page gave up); it then sends
//   `TabEvent.dialogCancelled(id)` and the reply ignores answers from then on.
// The look of every dialog is not in docs/arc-spec (unknown); the shell designs them.
// Plan C13 adds the password manager's save prompt and the autofill dropdown ([00 §A] observed:
// "inherited from the engine; prompts drawn by the shell, style not captured").

/// Single-shot answer channel of one dialog request. Thread-safe; equal by identity.
public final class DialogReply<Answer: Sendable>: Sendable, Hashable {
    public typealias Handler = @Sendable (Answer) -> Void

    /// What the request is answered with when nobody answers it.
    public let defaultAnswer: Answer
    private let handler: OSAllocatedUnfairLock<Handler?>

    /// - Parameter handler: called once, with the first answer (or the default when the reply is
    ///   released unanswered). Called on the thread that answers; it must not capture the request.
    public init(default defaultAnswer: Answer, handler: @escaping Handler) {
        self.defaultAnswer = defaultAnswer
        self.handler = OSAllocatedUnfairLock(initialState: handler)
    }

    deinit {
        take()?(defaultAnswer)
    }

    /// Answers the request. Returns false when it was already answered or withdrawn.
    @discardableResult
    public func send(_ answer: Answer) -> Bool {
        guard let handler = take() else { return false }
        handler(answer)
        return true
    }

    /// Answers with the default (the user closed the dialog without choosing).
    @discardableResult
    public func sendDefault() -> Bool { send(defaultAnswer) }

    /// Answered or withdrawn.
    public var isFinished: Bool { handler.withLock { $0 == nil } }

    /// Used by the engine when it withdraws the request: later answers are ignored and the
    /// handler is not called.
    public func withdraw() { _ = take() }

    private func take() -> Handler? {
        handler.withLock { state in
            defer { state = nil }
            return state
        }
    }

    public static func == (lhs: DialogReply, rhs: DialogReply) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// MARK: - JavaScript dialogs

/// alert(), confirm(), prompt() and the beforeunload prompt. Tab-modal.
public struct JavaScriptDialog: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case alert, confirm, prompt
        /// "Leave site?" (beforeunload). The message is the engine's text; pages cannot set it.
        case beforeUnload
    }

    public let id: UUID
    /// nil for opaque origins (data: URLs, sandboxed frames): the shell shows "This page".
    public let origin: SiteOrigin?
    public let isFromSubframe: Bool
    public let kind: Kind
    public let message: String
    /// prompt() default text; empty otherwise.
    public let defaultPromptText: String
    /// beforeunload for a reload rather than leaving the page (button text differs).
    public let isReload: Bool
    /// Offer "Prevent this page from creating additional dialogs".
    public let showsSuppressOption: Bool
    public let reply: DialogReply<JavaScriptDialogReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, kind: Kind, message: String,
        defaultPromptText: String = "", isReload: Bool = false, showsSuppressOption: Bool = false,
        reply: DialogReply<JavaScriptDialogReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.kind = kind
        self.message = message
        self.defaultPromptText = defaultPromptText
        self.isReload = isReload
        self.showsSuppressOption = showsSuppressOption
        self.reply = reply
    }
}

/// Answer to a JavaScript dialog.
public struct JavaScriptDialogReply: Hashable, Sendable {
    /// OK / Leave (true) or Cancel / Stay (false). An alert's only button counts as either.
    public var accepted: Bool
    /// prompt() text; nil otherwise or when cancelled.
    public var promptText: String?
    public var suppressFurtherDialogs: Bool

    public init(accepted: Bool, promptText: String? = nil, suppressFurtherDialogs: Bool = false) {
        self.accepted = accepted
        self.promptText = promptText
        self.suppressFurtherDialogs = suppressFurtherDialogs
    }

    /// Default: dismissed.
    public static let dismissed = JavaScriptDialogReply(accepted: false)
}

// MARK: - HTTP authentication

/// HTTP Basic/Digest auth and proxy auth.
public struct AuthenticationChallenge: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let isFromSubframe: Bool
    /// The realm string the server sent (shown as-is, untrusted).
    public let realm: String
    /// The server or proxy host and port that asks.
    public let challengerHostPort: String
    public let isProxy: Bool
    /// The connection is not encrypted (the dialog warns).
    public let isInsecureConnection: Bool
    /// From the password manager (C13), if any.
    public let suggestedUsername: String?
    public let reply: DialogReply<AuthenticationReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, realm: String, challengerHostPort: String,
        isProxy: Bool = false, isInsecureConnection: Bool = false, suggestedUsername: String? = nil,
        reply: DialogReply<AuthenticationReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.realm = realm
        self.challengerHostPort = challengerHostPort
        self.isProxy = isProxy
        self.isInsecureConnection = isInsecureConnection
        self.suggestedUsername = suggestedUsername
        self.reply = reply
    }
}

/// Answer to an authentication challenge. Default: `.cancel`.
public enum AuthenticationReply: Hashable, Sendable {
    case proceed(username: String, password: String)
    case cancel
}

// MARK: - Permissions

/// A permission prompt. Requests that arrive together (camera + microphone) are one prompt.
public struct PermissionPrompt: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let isFromSubframe: Bool
    /// In the engine's display order; never empty.
    public let kinds: [SitePermissionKind]
    public let hasUserGesture: Bool
    /// Every kind supports a one-time grant (Chromium: camera, microphone, location). When false,
    /// `.allow(remember: false)` is stored like `.allow(remember: true)`, so the prompt offers no
    /// "this time" choice.
    public let supportsAllowingOnce: Bool
    public let reply: DialogReply<PermissionReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, kinds: [SitePermissionKind],
        hasUserGesture: Bool = true, supportsAllowingOnce: Bool = true, reply: DialogReply<PermissionReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.kinds = kinds
        self.hasUserGesture = hasUserGesture
        self.supportsAllowingOnce = supportsAllowingOnce
        self.reply = reply
    }
}

/// Answer to a permission prompt. Default: `.dismiss` (no decision stored).
public enum PermissionReply: Hashable, Sendable {
    /// `remember` false: this time only (until the page closes); true: stored for the origin.
    case allow(remember: Bool)
    /// Chromium stores "block" for the origin whatever `remember` says (its prompt has no one-time
    /// block).
    case deny(remember: Bool)
    case dismiss
}

// MARK: - File chooser

/// `<input type=file>` and the File System Access pickers.
public struct FileChooserRequest: Identifiable, Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        case open, openMultiple, openFolder
        /// showSaveFilePicker().
        case save
    }

    public let id: UUID
    public let origin: SiteOrigin?
    public let isFromSubframe: Bool
    public let mode: Mode
    /// Uniform type identifiers from the `accept` attribute; empty: any file.
    public let acceptedTypeIdentifiers: [String]
    /// Suggested file name or starting folder.
    public let defaultURL: URL?
    public let reply: DialogReply<FileChooserReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, mode: Mode,
        acceptedTypeIdentifiers: [String] = [], defaultURL: URL? = nil, reply: DialogReply<FileChooserReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.mode = mode
        self.acceptedTypeIdentifiers = acceptedTypeIdentifiers
        self.defaultURL = defaultURL
        self.reply = reply
    }
}

/// Answer to a file chooser. Default: `.cancel`.
public enum FileChooserReply: Hashable, Sendable {
    case select([URL])
    case cancel
}

// MARK: - External protocol

/// A navigation to a scheme the engine cannot handle (mailto:, zoommtg:…), when the engine's policy
/// asks the user.
public struct ExternalProtocolRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let isFromSubframe: Bool
    public let url: URL
    /// Display name of the app that handles the scheme; nil if none.
    public let handlerApplicationName: String?
    /// Bundle URL of that app, for its icon.
    public let handlerApplicationURL: URL?
    public let hasUserGesture: Bool
    /// The engine may remember "always allow" for the origin (Chromium: a potentially trustworthy
    /// origin, and the policy allows it). When false the dialog offers no checkbox.
    public let canRememberForOrigin: Bool
    public let reply: DialogReply<ExternalProtocolReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, url: URL, handlerApplicationName: String?,
        handlerApplicationURL: URL? = nil, hasUserGesture: Bool = true, canRememberForOrigin: Bool = true,
        reply: DialogReply<ExternalProtocolReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.url = url
        self.handlerApplicationName = handlerApplicationName
        self.handlerApplicationURL = handlerApplicationURL
        self.hasUserGesture = hasUserGesture
        self.canRememberForOrigin = canRememberForOrigin
        self.reply = reply
    }
}

/// Answer to an external protocol request. Default: `.block`.
public enum ExternalProtocolReply: Hashable, Sendable {
    /// Opens the handler app. `rememberForOrigin` stores "always allow" for the scheme on the origin.
    case open(rememberForOrigin: Bool)
    case block
}

// MARK: - Password manager (plan C13)

/// The password manager offers to save (or update) the credential the user just signed in with
/// (after a login form was submitted and the page moved on). The engine keeps the password; the
/// prompt shows `passwordLength` dots. Bridge: `OACPasswordSavePrompt`. Arc's look of this prompt
/// is not recorded ([00 §A]: "prompts drawn by the shell, style not captured"): unknown.
public struct PasswordSavePrompt: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A new credential for the site.
        case save
        /// A new password for a saved username.
        case update
    }

    public let id: UUID
    public let origin: SiteOrigin?
    public let kind: Kind
    /// The submitted username (may be empty; the prompt lets the user edit it).
    public let username: String
    public let passwordLength: Int
    public let reply: DialogReply<PasswordSaveReply>

    public init(
        id: UUID, origin: SiteOrigin?, kind: Kind = .save, username: String, passwordLength: Int,
        reply: DialogReply<PasswordSaveReply>
    ) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.username = username
        self.passwordLength = passwordLength
        self.reply = reply
    }
}

/// Answer to a password save prompt. Default: `.dismiss` (closed without a choice; the engine counts
/// dismissals and stops offering on a site after a few, Chromium's rule).
public enum PasswordSaveReply: Hashable, Sendable {
    /// Save or update. A non-nil `username` replaces the submitted one.
    case save(username: String?)
    /// Never offer for this site (save prompts; an update prompt treats it as `.decline`).
    case neverForThisSite
    /// Not now / no thanks.
    case decline
    case dismiss
}

/// One row of the autofill dropdown.
public struct AutofillSuggestion: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A saved credential (`mainText` is the username).
        case password
        case address
        case creditCard
        /// A value typed earlier into a field of the same name.
        case autocomplete
        /// A `<datalist>` option.
        case dataList
        /// Another command ("Manage passwords…", "Clear form", a notice).
        case action
        /// A heading (not selectable).
        case title
        /// A divider line (not selectable).
        case separator
    }

    public var kind: Kind
    /// First line: the value that would be filled.
    public var mainText: String
    /// More first-line text (may be empty).
    public var minorText: String
    /// Second line (masked password, address summary…; may be empty).
    public var label: String
    public var isSelectable: Bool
    public var isAcceptable: Bool

    public init(
        kind: Kind, mainText: String, minorText: String = "", label: String = "",
        isSelectable: Bool = true, isAcceptable: Bool = true
    ) {
        self.kind = kind
        self.mainText = mainText
        self.minorText = minorText
        self.label = label
        self.isSelectable = isSelectable
        self.isAcceptable = isAcceptable
    }
}

/// A rectangle in points. (This module stays free of CoreGraphics; the shell converts.)
public struct EngineRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

}

/// What the autofill dropdown shows now.
public struct AutofillPopupState: Hashable, Sendable {
    public var suggestions: [AutofillSuggestion]
    /// The form field, in points, in the tab view's coordinates (origin top left, y down).
    public var elementBounds: EngineRect
    /// The field's text runs right to left (the dropdown aligns to the field's right edge).
    public var isRightToLeft: Bool
    /// The highlighted row.
    public var selectedIndex: Int?

    public init(suggestions: [AutofillSuggestion], elementBounds: EngineRect, isRightToLeft: Bool = false, selectedIndex: Int? = nil) {
        self.suggestions = suggestions
        self.elementBounds = elementBounds
        self.isRightToLeft = isRightToLeft
        self.selectedIndex = selectedIndex
    }
}

/// What the shell tells a live autofill dropdown.
public enum AutofillPopupCommand: Hashable, Sendable {
    /// Highlight a row (pointer hover); nil clears it. The engine previews it in the form.
    case select(Int?)
    /// Choose a row: the engine fills the form and then withdraws the dropdown. The engine ignores
    /// choices in the first half second after the dropdown appeared (Chromium's guard).
    case accept(Int)
    /// The pointer is over the dropdown: the engine keeps it open when the page loses focus to the
    /// click that follows.
    case pointerInside(Bool)
}

/// The live side of an autofill dropdown: its current rows (`state`, updated while the user types or
/// presses ↑ / ↓ in the page) and the commands the shell sends. Thread-safe; equal by identity.
public final class AutofillPopupSession: Sendable, Hashable {
    public typealias CommandHandler = @Sendable (AutofillPopupCommand) -> Void

    private let current: OSAllocatedUnfairLock<AutofillPopupState>
    private let broadcaster = AsyncBroadcaster<AutofillPopupState>()
    private let handler: CommandHandler

    public init(state: AutofillPopupState, handler: @escaping CommandHandler) {
        current = OSAllocatedUnfairLock(initialState: state)
        self.handler = handler
    }

    public var state: AutofillPopupState { current.withLock { $0 } }

    /// The state now, then every change; finishes when the engine ends the session.
    public func updates() -> AsyncStream<AutofillPopupState> {
        current.withLock { broadcaster.subscribe(initial: [$0]) }
    }

    /// Shell side.
    public func send(_ command: AutofillPopupCommand) { handler(command) }

    /// Engine side: new rows, bounds or highlight.
    public func update(_ state: AutofillPopupState) {
        current.withLock {
            $0 = state
            broadcaster.yield(state)
        }
    }

    /// Engine side: the dropdown went away.
    public func finish() { broadcaster.finish() }

    public static func == (lhs: AutofillPopupSession, rhs: AutofillPopupSession) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The autofill dropdown under the focused form field (saved passwords, addresses, cards, earlier
/// entries). Not modal: keyboard focus stays in the page. Bridge: `OACAutofillPopup`. Look:
/// unknown ([00 §A]).
public struct AutofillPopup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let session: AutofillPopupSession
    /// Closing without a choice (Escape in the shell, a click elsewhere). Choosing a row goes
    /// through `session` (`.accept`), after which the engine withdraws the request.
    public let reply: DialogReply<AutofillPopupReply>

    public init(id: UUID, origin: SiteOrigin?, session: AutofillPopupSession, reply: DialogReply<AutofillPopupReply>) {
        self.id = id
        self.origin = origin
        self.session = session
        self.reply = reply
    }
}

/// Answer to an autofill dropdown. Default: `.dismiss`.
public enum AutofillPopupReply: Hashable, Sendable {
    case dismiss
}

// MARK: - Extension install

/// "Add <extension>?": Chromium's install confirmation (a Web Store install, a re-enable after new
/// permissions), plan C14. Bridge: `OACExtensionInstallRequest`. Tab-modal over the store page.
/// The look is not in the spec (the Web Store flow was not observed): unknown.
public struct ExtensionInstallPrompt: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let extensionID: String
    public let extensionName: String
    public let iconPNGData: Data?
    /// Chromium's localized title, accept and cancel labels (the shell may use its own).
    public let title: String
    public let acceptTitle: String
    public let cancelTitle: String
    /// "Read and change all your data on all websites", in Chromium's order; may be empty.
    public let permissionWarnings: [String]
    public let reply: DialogReply<ExtensionInstallReply>

    public init(
        id: UUID, origin: SiteOrigin?, extensionID: String, extensionName: String, iconPNGData: Data? = nil,
        title: String, acceptTitle: String = "Add extension", cancelTitle: String = "Cancel",
        permissionWarnings: [String] = [], reply: DialogReply<ExtensionInstallReply>
    ) {
        self.id = id
        self.origin = origin
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.iconPNGData = iconPNGData
        self.title = title
        self.acceptTitle = acceptTitle
        self.cancelTitle = cancelTitle
        self.permissionWarnings = permissionWarnings
        self.reply = reply
    }
}

/// Answer to an install confirmation. Default: `.cancel`.
public enum ExtensionInstallReply: Hashable, Sendable {
    case add
    case cancel
}

// MARK: - Request

/// One dialog request of a tab (`BrowserTab.dialogRequests()`).
public enum EngineDialogRequest: Identifiable, Hashable, Sendable {
    case javaScript(JavaScriptDialog)
    case authentication(AuthenticationChallenge)
    case permission(PermissionPrompt)
    case fileChooser(FileChooserRequest)
    case externalProtocol(ExternalProtocolRequest)
    /// Password manager save / update prompt (plan C13).
    case passwordSave(PasswordSavePrompt)
    /// Autofill dropdown under the focused field (plan C13). Not modal.
    case autofillPopup(AutofillPopup)
    /// Extension install confirmation (plan C14).
    case extensionInstall(ExtensionInstallPrompt)

    public var id: UUID {
        switch self {
        case .javaScript(let r): r.id
        case .authentication(let r): r.id
        case .permission(let r): r.id
        case .fileChooser(let r): r.id
        case .externalProtocol(let r): r.id
        case .passwordSave(let r): r.id
        case .autofillPopup(let r): r.id
        case .extensionInstall(let r): r.id
        }
    }

    public var origin: SiteOrigin? {
        switch self {
        case .javaScript(let r): r.origin
        case .authentication(let r): r.origin
        case .permission(let r): r.origin
        case .fileChooser(let r): r.origin
        case .externalProtocol(let r): r.origin
        case .passwordSave(let r): r.origin
        case .autofillPopup(let r): r.origin
        case .extensionInstall(let r): r.origin
        }
    }

    /// Answered or withdrawn.
    public var isFinished: Bool {
        switch self {
        case .javaScript(let r): r.reply.isFinished
        case .authentication(let r): r.reply.isFinished
        case .permission(let r): r.reply.isFinished
        case .fileChooser(let r): r.reply.isFinished
        case .externalProtocol(let r): r.reply.isFinished
        case .passwordSave(let r): r.reply.isFinished
        case .autofillPopup(let r): r.reply.isFinished
        case .extensionInstall(let r): r.reply.isFinished
        }
    }

    /// Answers with the request's default (the user closed the dialog without choosing).
    @discardableResult
    public func answerWithDefault() -> Bool {
        switch self {
        case .javaScript(let r): r.reply.sendDefault()
        case .authentication(let r): r.reply.sendDefault()
        case .permission(let r): r.reply.sendDefault()
        case .fileChooser(let r): r.reply.sendDefault()
        case .externalProtocol(let r): r.reply.sendDefault()
        case .passwordSave(let r): r.reply.sendDefault()
        case .autofillPopup(let r): r.reply.sendDefault()
        case .extensionInstall(let r): r.reply.sendDefault()
        }
    }

    /// Engine side: withdraws the request (see `DialogReply.withdraw`).
    public func withdraw() {
        switch self {
        case .javaScript(let r): r.reply.withdraw()
        case .authentication(let r): r.reply.withdraw()
        case .permission(let r): r.reply.withdraw()
        case .fileChooser(let r): r.reply.withdraw()
        case .externalProtocol(let r): r.reply.withdraw()
        case .passwordSave(let r): r.reply.withdraw()
        case .autofillPopup(let r): r.reply.withdraw()
        case .extensionInstall(let r): r.reply.withdraw()
        }
    }
}
