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
// "inherited from the engine; prompts drawn by the shell, style not captured"); plan C30 adds
// Autofill's address and payment-card save prompts on the same footing. F1 step 2 adds the
// unresponsive-page prompt (C22, [00 §A] inferred (analysis): "Page unresponsive" dialog for a hung
// page, wait or leave), the client-certificate picker (C25, [00 §A] inferred (analysis)) and the
// passkey / security-key dialog (C21, [00 §A] inferred (analysis): drawn by the shell) and engine
// info bars (C23, [00 §A] inferred (analysis): confirmation strips above the page).

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

// MARK: - Address and payment-card save prompts (plan C30)

/// Autofill offers to save the address the user just submitted in a form, or to update a saved
/// address with the submitted values. The engine decides when (a complete address, not saved yet,
/// not refused too often); texts are formatted by the engine. Bridge: `OACAddressSavePrompt`.
/// [00 §A] observed: "inherited from the engine; prompts drawn by the shell, style not
/// captured"; look unknown.
public struct AddressSavePrompt: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case save
        /// New values for a saved address (`changes` lists them).
        case update
    }

    /// One changed value of an update prompt.
    public struct Change: Hashable, Sendable {
        public enum Field: String, Hashable, Sendable {
            case name
            /// The postal address as one block.
            case address
            case email
            case phone
        }

        public var field: Field
        /// The saved value (empty when there was none).
        public var oldValue: String
        public var newValue: String

        public init(field: Field, oldValue: String, newValue: String) {
            self.field = field
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    public let id: UUID
    public let origin: SiteOrigin?
    public let kind: Kind
    /// Name and postal address as they would be saved, several lines.
    public let addressSummary: String
    /// May be empty.
    public let email: String
    /// May be empty.
    public let phone: String
    /// Update prompts only.
    public let changes: [Change]
    public let reply: DialogReply<AutofillSaveReply>

    public init(
        id: UUID, origin: SiteOrigin?, kind: Kind = .save, addressSummary: String, email: String = "",
        phone: String = "", changes: [Change] = [], reply: DialogReply<AutofillSaveReply>
    ) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.addressSummary = addressSummary
        self.email = email
        self.phone = phone
        self.changes = changes
        self.reply = reply
    }
}

/// Autofill offers to save the payment card the user just submitted, in the profile on this Mac
/// (never uploaded). The card number stays in the engine. Bridge: `OACCardSavePrompt`. [00 §A]
/// observed (see `AddressSavePrompt`); look unknown.
public struct CardSavePrompt: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A new card, without its security code.
        case card
        /// A new card with the security code the form submitted.
        case cardWithSecurityCode
        /// Only the security code of a card saved earlier.
        case securityCodeOnly
    }

    public let id: UUID
    public let origin: SiteOrigin?
    public let kind: Kind
    /// "Visa", "Mastercard"…; may be empty.
    public let network: String
    public let lastFourDigits: String
    /// "MM/YY"; may be empty.
    public let expiration: String
    /// May be empty.
    public let cardholderName: String
    public let reply: DialogReply<AutofillSaveReply>

    public init(
        id: UUID, origin: SiteOrigin?, kind: Kind = .card, network: String, lastFourDigits: String,
        expiration: String = "", cardholderName: String = "", reply: DialogReply<AutofillSaveReply>
    ) {
        self.id = id
        self.origin = origin
        self.kind = kind
        self.network = network
        self.lastFourDigits = lastFourDigits
        self.expiration = expiration
        self.cardholderName = cardholderName
        self.reply = reply
    }
}

/// Answer to an address or card save prompt. Default: `.ignore` (closed without a choice; the
/// engine counts it and stops offering after a few, Chromium's rule).
public enum AutofillSaveReply: Hashable, Sendable {
    case save
    /// "No thanks".
    case decline
    case ignore
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

// MARK: - Unresponsive page (plan C22)

/// The page stopped answering input (an endless script) for the engine's hang delay while it was
/// shown. [00 §A] inferred (analysis): the shell draws it and offers to wait or to leave the page.
/// The engine withdraws it when the page answers again, navigates or its renderer goes away.
/// Bridge: `OACUnresponsivePageRequest`.
public struct UnresponsivePagePrompt: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let reply: DialogReply<UnresponsivePageReply>

    public init(id: UUID, origin: SiteOrigin?, reply: DialogReply<UnresponsivePageReply>) {
        self.id = id
        self.origin = origin
        self.reply = reply
    }
}

/// Answer to an unresponsive-page prompt. Default: `.wait`.
public enum UnresponsivePageReply: Hashable, Sendable {
    /// Keep waiting; the engine asks again if the page is still stuck after another delay.
    case wait
    /// Stop the page's renderer and go back to the previous page (a tab with no previous page
    /// shows the crashed-page view; other tabs that shared the renderer crash too).
    case leave
}

// MARK: - Client certificate (plan C25)

/// One client certificate (a keychain identity) a site may get.
public struct ClientCertificate: Hashable, Sendable {
    /// The subject's display name (common name, else organization).
    public var subjectName: String
    public var issuerName: String
    public var validUntil: Date
    /// The certificate (DER), for a certificate viewer.
    public var derData: Data

    public init(subjectName: String, issuerName: String, validUntil: Date, derData: Data = Data()) {
        self.subjectName = subjectName
        self.issuerName = issuerName
        self.validUntil = validUntil
        self.derData = derData
    }
}

/// A server asked for a client certificate during the TLS handshake and the engine's policy did not
/// pick one. [00 §A] inferred (analysis): a picker for sites that ask for one; look unknown.
/// The engine withdraws it when the tab closes, the network request went away or another prompt for
/// the same host was answered. Bridge: `OACClientCertificateRequest`.
public struct ClientCertificatePrompt: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    /// The server that asks, "host:port".
    public let hostPort: String
    /// Never empty (with no identity the engine continues without asking).
    public let certificates: [ClientCertificate]
    public let reply: DialogReply<ClientCertificateReply>

    public init(id: UUID, origin: SiteOrigin?, hostPort: String, certificates: [ClientCertificate], reply: DialogReply<ClientCertificateReply>) {
        self.id = id
        self.origin = origin
        self.hostPort = hostPort
        self.certificates = certificates
        self.reply = reply
    }
}

/// Answer to a client-certificate prompt. Default: `.continueWithout`. The engine remembers either
/// answer for the host until the browsing session ends.
public enum ClientCertificateReply: Hashable, Sendable {
    /// Send `certificates[index]` (macOS may ask to allow access to its private key).
    case select(index: Int)
    /// Continue the handshake without a certificate (Cancel).
    case continueWithout
}

// MARK: - WebAuthn (plan C21)

/// The passkey / security-key dialog's current step. [00 §A] inferred (analysis); look and wording
/// unknown. Bridge: `OACWebAuthnDialog` (OACWebAuthn.h lists what is and is not supported).
public struct WebAuthnState: Hashable, Sendable {
    public enum Operation: Hashable, Sendable {
        /// `navigator.credentials.create()`.
        case create
        /// `navigator.credentials.get()`.
        case signIn
    }

    public enum Step: Hashable, Sendable {
        /// Choose how to continue (`mechanisms`).
        case chooseMethod
        /// Confirm `mechanisms[priorityMechanismIndex]`.
        case confirmMethod
        /// Insert and touch the security key (no button).
        case securityKey
        case enterPIN
        /// The key has no PIN yet: choose one (asked twice).
        case setPIN
        /// The key requires a new PIN (asked twice).
        case changePIN
        case touchAgain
        /// Touch the key's fingerprint sensor (`bioSamplesRemaining`); accept when done.
        case fingerprintEnrollment
        case retryVerification
        case confirmSecurityKeyStorage
        /// Choose the account (`accounts`).
        case chooseAccount
        /// Create a passkey on this Mac (macOS asks for Touch ID or the password next).
        case createPasskey
        case privateWindowWarning
        case error(WebAuthnError)
    }

    public enum MechanismKind: Hashable, Sendable {
        /// A passkey for one account on this Mac.
        case passkeyOnThisMac
        /// Save or use a passkey on this Mac.
        case thisMac
        case securityKey
        case other
    }

    public struct Mechanism: Hashable, Sendable {
        public var kind: MechanismKind
        /// The account for passkeys; empty otherwise.
        public var title: String
        public var subtitle: String

        public init(kind: MechanismKind, title: String = "", subtitle: String = "") {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Account: Hashable, Sendable {
        public var name: String
        public var displayName: String

        public init(name: String, displayName: String = "") {
            self.name = name
            self.displayName = displayName
        }
    }

    public enum PINError: Hashable, Sendable {
        case none, wrongPIN, tooShort, invalidCharacters, sameAsCurrent, fingerprintLocked
    }

    public var operation: Operation
    /// The relying party ("example.com").
    public var relyingPartyID: String
    /// For `.create`: the account the site creates a passkey for (may be empty).
    public var userName: String
    public var step: Step
    public var mechanisms: [Mechanism]
    public var priorityMechanismIndex: Int?
    public var accounts: [Account]
    public var canChooseAnotherMethod: Bool
    /// The error step offers "Try Again".
    public var canRetry: Bool
    public var pinError: PINError
    public var pinAttemptsRemaining: Int?
    public var minimumPINLength: Int
    public var bioSamplesRemaining: Int?
    public var bioSamplesTotal: Int?
    /// The engine is busy: no input until the next update.
    public var isBusy: Bool

    public init(
        operation: Operation, relyingPartyID: String, userName: String = "", step: Step,
        mechanisms: [Mechanism] = [], priorityMechanismIndex: Int? = nil, accounts: [Account] = [],
        canChooseAnotherMethod: Bool = false, canRetry: Bool = false, pinError: PINError = .none,
        pinAttemptsRemaining: Int? = nil, minimumPINLength: Int = 4, bioSamplesRemaining: Int? = nil,
        bioSamplesTotal: Int? = nil, isBusy: Bool = false
    ) {
        self.operation = operation
        self.relyingPartyID = relyingPartyID
        self.userName = userName
        self.step = step
        self.mechanisms = mechanisms
        self.priorityMechanismIndex = priorityMechanismIndex
        self.accounts = accounts
        self.canChooseAnotherMethod = canChooseAnotherMethod
        self.canRetry = canRetry
        self.pinError = pinError
        self.pinAttemptsRemaining = pinAttemptsRemaining
        self.minimumPINLength = minimumPINLength
        self.bioSamplesRemaining = bioSamplesRemaining
        self.bioSamplesTotal = bioSamplesTotal
        self.isBusy = isBusy
    }
}

/// Why a WebAuthn request failed.
public enum WebAuthnError: Hashable, Sendable {
    case timedOut
    case keyNotRegistered
    case keyAlreadyRegistered
    case noPasskeys
    case noMethods
    case pinTemporarilyLocked
    case pinLocked
    case keyRemoved
    case missingCapability
    case storageFull
    /// A method this app does not support (phone, Bluetooth, cloud passkeys).
    case unsupported
    case other
}

/// What the shell tells a live WebAuthn dialog.
public enum WebAuthnCommand: Hashable, Sendable {
    /// The step's main button (continue, create, try again, done).
    case accept
    case selectMechanism(Int)
    case selectAccount(Int)
    /// The PIN (for set / change: already confirmed by the shell).
    case providePIN(String)
    /// Back to the method list.
    case chooseAnotherMethod
}

/// The live side of a WebAuthn dialog: its current step (changes while it is open) and the commands
/// the shell sends. Thread-safe; equal by identity.
public final class WebAuthnSession: Sendable, Hashable {
    public typealias CommandHandler = @Sendable (WebAuthnCommand) -> Void

    private let current: OSAllocatedUnfairLock<WebAuthnState>
    private let broadcaster = AsyncBroadcaster<WebAuthnState>()
    private let handler: CommandHandler

    public init(state: WebAuthnState, handler: @escaping CommandHandler) {
        current = OSAllocatedUnfairLock(initialState: state)
        self.handler = handler
    }

    public var state: WebAuthnState { current.withLock { $0 } }

    /// The state now, then every change; finishes when the engine ends the session.
    public func updates() -> AsyncStream<WebAuthnState> {
        current.withLock { broadcaster.subscribe(initial: [$0]) }
    }

    /// Shell side.
    public func send(_ command: WebAuthnCommand) { handler(command) }

    /// Engine side: the dialog moved to another step or its content changed.
    public func update(_ state: WebAuthnState) {
        current.withLock {
            $0 = state
            broadcaster.yield(state)
        }
    }

    /// Engine side: the dialog went away.
    public func finish() { broadcaster.finish() }

    public static func == (lhs: WebAuthnSession, rhs: WebAuthnSession) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The passkey / security-key dialog of one WebAuthn request. Tab-modal. Steps change through
/// `session`; only cancelling answers the request (`reply`). The engine withdraws it when the flow
/// completes or hands over to macOS (Touch ID / password prompt). Bridge: `OACWebAuthnDialog`.
public struct WebAuthnDialog: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let origin: SiteOrigin?
    public let session: WebAuthnSession
    public let reply: DialogReply<WebAuthnReply>

    public init(id: UUID, origin: SiteOrigin?, session: WebAuthnSession, reply: DialogReply<WebAuthnReply>) {
        self.id = id
        self.origin = origin
        self.session = session
        self.reply = reply
    }
}

/// Answer to a WebAuthn dialog. Default: `.cancel` (the page gets NotAllowedError).
public enum WebAuthnReply: Hashable, Sendable {
    case cancel
}

// MARK: - Info bar (plan C23)

/// An engine info bar: a one-line strip the engine wants above the tab's page, with up to two
/// buttons, an optional link and a close button ("an extension is debugging this browser",
/// "reload to apply your new settings"). [00 §A] inferred (analysis): engine info bars
/// (confirmation strips above the page) are drawn by the shell; look unknown.
///
/// Not modal: the page stays usable, the tab's other requests show as usual, and several bars can
/// be open at once. The engine withdraws one when it goes away on its own (navigation, the feature
/// closed it, a newer bar replaced it); after an answer that keeps the bar open (the engine
/// decides), a new request for the same bar follows. A bar nobody answers stays open in the
/// engine, unseen: the default answer does nothing. Bridge: `OACInfoBarRequest`.
public struct InfoBarRequest: Identifiable, Hashable, Sendable {
    public struct Buttons: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let ok = Buttons(rawValue: 1 << 0)
        public static let cancel = Buttons(rawValue: 1 << 1)
    }

    public let id: UUID
    /// The engine's text, in its UI language.
    public let message: String
    /// The link after the message ("Learn more"), or nil.
    public let linkTitle: String?
    public let buttons: Buttons
    /// Empty for a button `buttons` lacks.
    public let okTitle: String
    public let cancelTitle: String
    /// The bar has a close (✕) button.
    public let isCloseable: Bool
    public let reply: DialogReply<InfoBarReply>

    public init(
        id: UUID, message: String, linkTitle: String? = nil, buttons: Buttons = [], okTitle: String = "",
        cancelTitle: String = "", isCloseable: Bool = true, reply: DialogReply<InfoBarReply>
    ) {
        self.id = id
        self.message = message
        self.linkTitle = linkTitle
        self.buttons = buttons
        self.okTitle = okTitle
        self.cancelTitle = cancelTitle
        self.isCloseable = isCloseable
        self.reply = reply
    }
}

/// Answer to an info bar. Default: `.leaveOpen`.
public enum InfoBarReply: Hashable, Sendable {
    case accept
    case decline
    /// The close button.
    case close
    /// The link: the engine opens its page in a new tab (an `EngineEvent.newTabRequested`).
    case openLink
    /// No answer (the shell dropped the request): the bar stays open in the engine.
    case leaveOpen
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
    /// Autofill's address save / update prompt (plan C30).
    case addressSave(AddressSavePrompt)
    /// Autofill's payment-card save prompt (plan C30).
    case cardSave(CardSavePrompt)
    /// Extension install confirmation (plan C14).
    case extensionInstall(ExtensionInstallPrompt)
    /// The page stopped responding (plan C22).
    case unresponsivePage(UnresponsivePagePrompt)
    /// A site asks for a client certificate (plan C25).
    case clientCertificate(ClientCertificatePrompt)
    /// The passkey / security-key dialog (plan C21).
    case webAuthn(WebAuthnDialog)
    /// An engine info bar above the page (plan C23). Not modal.
    case infoBar(InfoBarRequest)

    public var id: UUID {
        switch self {
        case .javaScript(let r): r.id
        case .authentication(let r): r.id
        case .permission(let r): r.id
        case .fileChooser(let r): r.id
        case .externalProtocol(let r): r.id
        case .passwordSave(let r): r.id
        case .autofillPopup(let r): r.id
        case .addressSave(let r): r.id
        case .cardSave(let r): r.id
        case .extensionInstall(let r): r.id
        case .unresponsivePage(let r): r.id
        case .clientCertificate(let r): r.id
        case .webAuthn(let r): r.id
        case .infoBar(let r): r.id
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
        case .addressSave(let r): r.origin
        case .cardSave(let r): r.origin
        case .extensionInstall(let r): r.origin
        case .unresponsivePage(let r): r.origin
        case .clientCertificate(let r): r.origin
        case .webAuthn(let r): r.origin
        case .infoBar: nil
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
        case .addressSave(let r): r.reply.isFinished
        case .cardSave(let r): r.reply.isFinished
        case .extensionInstall(let r): r.reply.isFinished
        case .unresponsivePage(let r): r.reply.isFinished
        case .clientCertificate(let r): r.reply.isFinished
        case .webAuthn(let r): r.reply.isFinished
        case .infoBar(let r): r.reply.isFinished
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
        case .addressSave(let r): r.reply.sendDefault()
        case .cardSave(let r): r.reply.sendDefault()
        case .extensionInstall(let r): r.reply.sendDefault()
        case .unresponsivePage(let r): r.reply.sendDefault()
        case .clientCertificate(let r): r.reply.sendDefault()
        case .webAuthn(let r): r.reply.sendDefault()
        case .infoBar(let r): r.reply.sendDefault()
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
        case .addressSave(let r): r.reply.withdraw()
        case .cardSave(let r): r.reply.withdraw()
        case .extensionInstall(let r): r.reply.withdraw()
        case .unresponsivePage(let r): r.reply.withdraw()
        case .clientCertificate(let r): r.reply.withdraw()
        case .webAuthn(let r): r.reply.withdraw()
        case .infoBar(let r): r.reply.withdraw()
        }
    }
}
