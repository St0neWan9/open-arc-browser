import SwiftUI
import OpenArcEngine
import OpenArcDesign

// The passkey / security-key sheet (plan C21). [00 §A] inferred (analysis): the dialog exists and
// the shell draws it; Arc's look and wording are not recorded, so every text, size and layout here is
// ours (unknown). Behavior is the engine's: each step of its flow arrives as a `WebAuthnState`
// (OACWebAuthn.h), and the buttons send `WebAuthnCommand`s. Cancel answers the request (the page gets
// NotAllowedError); everything else keeps it open until the engine withdraws it.

/// What the sheet shows for one state. No UI types, so it is unit-testable.
public struct WebAuthnPresentation: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case none
        /// One secure field.
        case pin
        /// A new PIN, typed twice.
        case newPIN
    }

    public struct Row: Equatable, Sendable {
        public var symbol: String
        public var title: String
        public var detail: String
    }

    public var title: String
    public var message: String
    public var input: Input
    /// Rows to click (methods or accounts); empty when the step has none.
    public var rows: [Row]
    /// The main button, if the step has one (Return).
    public var acceptTitle: String?
    public var showsChooseAnotherMethod: Bool
    /// The step waits for the security key or the engine (a spinner).
    public var showsProgress: Bool
    public var errorText: String?

    public init(_ state: WebAuthnState) {
        let site = state.relyingPartyID.isEmpty ? "this site" : state.relyingPartyID
        let creating = state.operation == .create
        input = .none
        rows = []
        acceptTitle = nil
        showsChooseAnotherMethod = state.canChooseAnotherMethod
        showsProgress = state.isBusy
        errorText = nil
        switch state.step {
        case .chooseMethod, .confirmMethod:
            title = creating ? "Create a passkey for \(site)" : "Use a passkey for \(site)"
            message = creating ? "Choose where to save it." : "Choose how to sign in."
            let shown: [WebAuthnState.Mechanism]
            if state.step == .confirmMethod, let index = state.priorityMechanismIndex, state.mechanisms.indices.contains(index) {
                shown = [state.mechanisms[index]]
                acceptTitle = "Continue"
            } else {
                shown = state.mechanisms
            }
            rows = shown.map { Self.row(for: $0) }
        case .securityKey:
            title = "Use your security key"
            message = "Insert your security key and touch it."
            showsProgress = true
        case .enterPIN:
            title = "Enter your security key’s PIN"
            message = state.pinAttemptsRemaining.map { $0 <= 3 ? "\($0) attempts left before the key locks." : "" } ?? ""
            input = .pin
            acceptTitle = "Continue"
        case .setPIN:
            title = "Create a PIN for your security key"
            message = "Use at least \(state.minimumPINLength) characters."
            input = .newPIN
            acceptTitle = "Continue"
        case .changePIN:
            title = "Change your security key’s PIN"
            message = "Your security key requires a new PIN of at least \(state.minimumPINLength) characters."
            input = .newPIN
            acceptTitle = "Continue"
        case .touchAgain:
            title = "Touch your security key again"
            message = "Touch your security key to finish."
            showsProgress = true
        case .fingerprintEnrollment:
            title = "Add a fingerprint to your security key"
            if let remaining = state.bioSamplesRemaining, remaining <= 0 {
                message = "Your fingerprint was added."
                acceptTitle = "Done"
            } else {
                message = "Touch the key’s sensor until your fingerprint is captured."
                showsProgress = true
            }
        case .retryVerification:
            title = "Try again"
            message = "Your fingerprint wasn’t recognized. Touch your security key again."
            showsProgress = true
        case .confirmSecurityKeyStorage:
            title = "Save sign-in data on your security key?"
            message = "\(site) wants to store information about your account on the key."
            acceptTitle = "Continue"
        case .chooseAccount:
            title = "Choose an account for \(site)"
            message = ""
            rows = state.accounts.map {
                Row(symbol: "person.crop.circle",
                    title: $0.name.isEmpty ? $0.displayName : $0.name,
                    detail: $0.name.isEmpty ? "" : $0.displayName)
            }
        case .createPasskey:
            title = "Create a passkey for \(site)"
            message = state.userName.isEmpty
                ? "Save a passkey on this Mac. You’ll use Touch ID or your password to sign in."
                : "Save a passkey for \(state.userName) on this Mac. You’ll use Touch ID or your password to sign in."
            acceptTitle = "Continue"
        case .privateWindowWarning:
            title = "You’re in a private window"
            message = "A passkey you save will stay on this Mac after you close the window."
            acceptTitle = "Continue"
        case .error(let error):
            title = Self.errorTitle(error)
            message = Self.errorMessage(error, site: site)
            showsProgress = false
            if state.canRetry { acceptTitle = "Try Again" }
        }
        if input != .none {
            errorText = Self.pinErrorText(state.pinError, minimumLength: state.minimumPINLength)
        }
    }

    static func row(for mechanism: WebAuthnState.Mechanism) -> Row {
        switch mechanism.kind {
        case .passkeyOnThisMac:
            Row(symbol: "person.badge.key", title: mechanism.title, detail: "Passkey on this Mac")
        case .thisMac:
            Row(symbol: "laptopcomputer", title: "This Mac", detail: "Touch ID or your password")
        case .securityKey:
            Row(symbol: "key.horizontal", title: "Security key", detail: "USB or NFC")
        case .other:
            Row(symbol: "ellipsis.circle", title: mechanism.title.isEmpty ? "Another method" : mechanism.title, detail: mechanism.subtitle)
        }
    }

    static func errorTitle(_ error: WebAuthnError) -> String {
        switch error {
        case .timedOut: "The request timed out"
        case .noPasskeys: "No passkeys found"
        case .pinTemporarilyLocked, .pinLocked: "Security key locked"
        default: "Something went wrong"
        }
    }

    static func errorMessage(_ error: WebAuthnError, site: String) -> String {
        switch error {
        case .timedOut: "The site stopped waiting. Try again from the page."
        case .keyNotRegistered: "This security key isn’t registered with \(site)."
        case .keyAlreadyRegistered: "This security key is already registered with \(site)."
        case .noPasskeys: "There are no passkeys for \(site) on this Mac."
        case .noMethods: "This Mac can’t create or use passkeys for \(site). Try a security key."
        case .pinTemporarilyLocked: "Too many wrong PINs. Remove your security key, insert it again and retry."
        case .pinLocked: "Too many wrong PINs. Your security key must be reset."
        case .keyRemoved: "Your security key was removed."
        case .missingCapability: "Your security key doesn’t support what \(site) asks for."
        case .storageFull: "Your security key has no room for another passkey."
        case .unsupported: "This method isn’t available in Open Arc. Use a passkey on this Mac or a security key."
        case .other: "The request couldn’t be completed."
        }
    }

    static func pinErrorText(_ error: WebAuthnState.PINError, minimumLength: Int) -> String? {
        switch error {
        case .none: nil
        case .wrongPIN: "Incorrect PIN."
        case .tooShort: "The PIN must have at least \(minimumLength) characters."
        case .invalidCharacters: "The PIN contains characters that aren’t allowed."
        case .sameAsCurrent: "Choose a PIN different from the current one."
        case .fingerprintLocked: "Fingerprint unlock is locked. Enter your PIN."
        }
    }

    /// The command for the main button with the typed PIN(s), or the shell-side error when the two
    /// new PINs differ.
    public static func acceptCommand(for state: WebAuthnState, pin: String, confirmation: String) -> Result<WebAuthnCommand, PINMismatch> {
        switch WebAuthnPresentation(state).input {
        case .none: .success(.accept)
        case .pin: .success(.providePIN(pin))
        case .newPIN: pin == confirmation ? .success(.providePIN(pin)) : .failure(PINMismatch())
        }
    }

    /// The command for clicking row `index`.
    public static func rowCommand(for state: WebAuthnState, row index: Int) -> WebAuthnCommand? {
        switch state.step {
        case .chooseMethod:
            state.mechanisms.indices.contains(index) ? .selectMechanism(index) : nil
        case .confirmMethod:
            .accept
        case .chooseAccount:
            state.accounts.indices.contains(index) ? .selectAccount(index) : nil
        default:
            nil
        }
    }

    public struct PINMismatch: Error, Equatable {
        public let message = "The PINs don’t match."
    }
}

/// The sheet: title, message, rows or PIN fields, and Cancel / "Use another method" / the main
/// button. Its content follows the session's state.
struct WebAuthnSheetView: View {
    let center: DialogCenter
    let dialog: WebAuthnDialog
    @State private var state: WebAuthnState
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var localError: String?

    init(center: DialogCenter, dialog: WebAuthnDialog) {
        self.center = center
        self.dialog = dialog
        _state = State(initialValue: dialog.session.state)
    }

    var body: some View {
        let presentation = WebAuthnPresentation(state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.secondary)
                Text(presentation.title)
                    .font(Typography.dialogBody.font.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.message.isEmpty {
                Text(presentation.message)
                    .font(Typography.settingsBody.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.rows.isEmpty {
                rows(presentation.rows)
            }
            switch presentation.input {
            case .none:
                EmptyView()
            case .pin:
                SecureField("PIN", text: $pin).textFieldStyle(.roundedBorder).onSubmit(accept)
            case .newPIN:
                SecureField("New PIN", text: $pin).textFieldStyle(.roundedBorder)
                SecureField("Confirm PIN", text: $confirmation).textFieldStyle(.roundedBorder).onSubmit(accept)
            }
            if let error = localError ?? presentation.errorText {
                Text(error)
                    .font(Typography.settingsBody.font)
                    .foregroundStyle(.red)
            }
            HStack {
                if presentation.showsProgress {
                    ProgressView().controlSize(.small)
                }
                if presentation.showsChooseAnotherMethod {
                    Button("Use Another Method") { dialog.session.send(.chooseAnotherMethod) }
                        .controlSize(.small)
                        .disabled(state.isBusy)
                }
                Spacer()
                Button("Cancel") { center.answer(dialog.id, with: .webAuthn(.cancel)) }
                    .controlSize(.small)
                if let accept = presentation.acceptTitle {
                    Button(accept, action: self.accept)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .disabled(state.isBusy)
                }
            }
        }
        .padding(DialogLocalTokens.padding)
        .background(
            RoundedRectangle(cornerRadius: DialogLocalTokens.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .onExitCommand { center.dismiss(dialog.id) }
        .task {
            for await next in dialog.session.updates() {
                if next.step != state.step {
                    pin = ""
                    confirmation = ""
                    localError = nil
                }
                state = next
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.dialog.webauthn")
    }

    private func rows(_ rows: [WebAuthnPresentation.Row]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Button {
                    if let command = WebAuthnPresentation.rowCommand(for: state, row: index) {
                        dialog.session.send(command)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(Typography.settingsBody.font.weight(.medium))
                            if !row.detail.isEmpty {
                                Text(row.detail).font(Typography.settingsBody.font).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                .accessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.3)))
    }

    private func accept() {
        switch WebAuthnPresentation.acceptCommand(for: state, pin: pin, confirmation: confirmation) {
        case .success(let command):
            localError = nil
            dialog.session.send(command)
        case .failure(let mismatch):
            localError = mismatch.message
        }
    }
}
