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
    public let reply: DialogReply<PermissionReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, kinds: [SitePermissionKind],
        hasUserGesture: Bool = true, reply: DialogReply<PermissionReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.kinds = kinds
        self.hasUserGesture = hasUserGesture
        self.reply = reply
    }
}

/// Answer to a permission prompt. Default: `.dismiss` (no decision stored).
public enum PermissionReply: Hashable, Sendable {
    /// `remember` false: this time only (until the page closes); true: stored for the origin.
    case allow(remember: Bool)
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
    public let reply: DialogReply<ExternalProtocolReply>

    public init(
        id: UUID, origin: SiteOrigin?, isFromSubframe: Bool = false, url: URL, handlerApplicationName: String?,
        handlerApplicationURL: URL? = nil, hasUserGesture: Bool = true, reply: DialogReply<ExternalProtocolReply>
    ) {
        self.id = id
        self.origin = origin
        self.isFromSubframe = isFromSubframe
        self.url = url
        self.handlerApplicationName = handlerApplicationName
        self.handlerApplicationURL = handlerApplicationURL
        self.hasUserGesture = hasUserGesture
        self.reply = reply
    }
}

/// Answer to an external protocol request. Default: `.block`.
public enum ExternalProtocolReply: Hashable, Sendable {
    /// Opens the handler app. `rememberForOrigin` stores "always allow" for the scheme on the origin.
    case open(rememberForOrigin: Bool)
    case block
}

// MARK: - Request

/// One dialog request of a tab (`BrowserTab.dialogRequests()`).
public enum EngineDialogRequest: Identifiable, Hashable, Sendable {
    case javaScript(JavaScriptDialog)
    case authentication(AuthenticationChallenge)
    case permission(PermissionPrompt)
    case fileChooser(FileChooserRequest)
    case externalProtocol(ExternalProtocolRequest)

    public var id: UUID {
        switch self {
        case .javaScript(let r): r.id
        case .authentication(let r): r.id
        case .permission(let r): r.id
        case .fileChooser(let r): r.id
        case .externalProtocol(let r): r.id
        }
    }

    public var origin: SiteOrigin? {
        switch self {
        case .javaScript(let r): r.origin
        case .authentication(let r): r.origin
        case .permission(let r): r.origin
        case .fileChooser(let r): r.origin
        case .externalProtocol(let r): r.origin
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
        }
    }
}
