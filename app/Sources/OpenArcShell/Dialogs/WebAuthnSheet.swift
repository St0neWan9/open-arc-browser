import SwiftUI
import CoreImage
import OpenArcEngine
import OpenArcDesign

// The passkey / security-key sheet (plan C21). [00 §A] inferred: the dialog exists and
// the shell draws it; Arc's look and wording are not recorded, so every text, size and layout here is
// ours (unknown). Behavior is the engine's: each step of its flow arrives as a `WebAuthnState`
// (OACWebAuthn.h), and the buttons send `WebAuthnCommand`s. Cancel answers the request (the page gets
// NotAllowedError); everything else keeps it open until the engine withdraws it. Since B197 it is
// drawn as a prompt card (PromptCard.swift: the card family of [06 §41]), inferred.
//
// Plan B155, phones and tablets (hybrid): the method list offers "Phone or tablet"; its step shows a
// QR code the phone's camera scans, then "connecting" and "continue on your phone". Bluetooth must
// be allowed and on first; those steps say how. Arc's look of these steps is not recorded in
// docs/arc-spec (unknown); the layout follows the rest of this sheet with the QR code centered,
// inferred from Chromium's own sheet.

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
    /// The main button can be pressed (besides `isBusy`): Bluetooth's "Continue" waits for power.
    public var acceptEnabled: Bool
    /// Plan B155: the text to draw as a QR code (`.phoneQRCode`), else nil.
    public var qrCode: String?
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
        acceptEnabled = true
        qrCode = nil
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
            rows = shown.map { Self.row(for: $0, acceptsSecurityKey: state.phoneStepAcceptsSecurityKey) }
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
        case .phoneQRCode:
            title = "Use a phone or tablet"
            let action = creating ? "save a passkey for \(site)" : "sign in to \(site)"
            message = "Scan this QR code with the camera of your phone or tablet to \(action)."
            if state.phoneStepAcceptsSecurityKey {
                message += " You can also use a security key."
            }
            qrCode = state.phoneQRCode.isEmpty ? nil : state.phoneQRCode
        case .phoneConnecting:
            title = "Connecting to your device"
            message = "Keep your phone or tablet nearby with Bluetooth on."
            showsProgress = true
        case .phoneConnected:
            title = "Continue on your device"
            message = "Follow the steps on your phone or tablet."
        case .turnOnBluetooth:
            title = "Turn on Bluetooth?"
            message = "Bluetooth must be on to use a passkey from your phone or tablet."
            acceptTitle = "Turn On"
        case .bluetoothOff:
            title = "Bluetooth is off"
            message = "Turn on Bluetooth in Control Center or System Settings ▸ Bluetooth, then continue."
            acceptTitle = "Continue"
            acceptEnabled = state.bluetoothIsPowered
        case .bluetoothPermission:
            title = "Allow Bluetooth"
            message = "Open Arc needs Bluetooth to connect to your phone or tablet. Turn on Open Arc in "
                + "System Settings ▸ Privacy & Security ▸ Bluetooth, then reopen Open Arc."
            acceptTitle = "Open System Settings"
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

    static func row(for mechanism: WebAuthnState.Mechanism, acceptsSecurityKey: Bool = false) -> Row {
        switch mechanism.kind {
        case .passkeyOnThisMac:
            Row(symbol: "person.badge.key", title: mechanism.title, detail: "Passkey on this Mac")
        case .thisMac:
            Row(symbol: "laptopcomputer", title: "This Mac", detail: "Touch ID or your password")
        case .securityKey:
            Row(symbol: "key.horizontal", title: "Security key", detail: "USB or NFC")
        case .other:
            Row(symbol: "ellipsis.circle", title: mechanism.title.isEmpty ? "Another method" : mechanism.title, detail: mechanism.subtitle)
        case .iCloudKeychain:
            Row(symbol: "key.icloud", title: "iCloud Keychain", detail: "Passwords or another passkey app")
        case .passkeyInICloudKeychain:
            Row(symbol: "key.icloud", title: mechanism.title,
                detail: mechanism.subtitle.isEmpty ? "Passkey in iCloud Keychain" : "Passkey in \(mechanism.subtitle)")
        case .phone:
            Row(symbol: "iphone",
                title: acceptsSecurityKey ? "Phone, tablet or security key" : "Phone or tablet",
                detail: "Scan a QR code")
        }
    }

    static func errorTitle(_ error: WebAuthnError) -> String {
        switch error {
        case .timedOut: "The request timed out"
        case .noPasskeys: "No passkeys found"
        case .pinTemporarilyLocked, .pinLocked: "Security key locked"
        case .phoneConnectionFailed: "Couldn’t connect to your device"
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
        case .unsupported: "This sign-in method isn’t available in Open Arc. Choose another way to sign in on the page."
        case .other: "The request couldn’t be completed."
        case .phoneConnectionFailed:
            "Check that Bluetooth and the internet are on, on this Mac and on your phone or tablet. Then try again from the page."
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

/// The passkey card: title, message, rows or PIN fields, and "Use Another Method" / Cancel / the
/// main button, as a prompt card (B197, inferred). Its content follows the session's state.
struct WebAuthnSheetView: View {
    let center: DialogCenter
    let dialog: WebAuthnDialog
    let palette: ThemePalette
    @State private var state: WebAuthnState
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var localError: String?

    init(center: DialogCenter, dialog: WebAuthnDialog, palette: ThemePalette) {
        self.center = center
        self.dialog = dialog
        self.palette = palette
        _state = State(initialValue: dialog.session.state)
    }

    var body: some View {
        let presentation = WebAuthnPresentation(state)
        let t = PromptCardTokens.self
        PromptCard(palette: palette, header: .symbol("person.badge.key.fill"), title: presentation.title,
                   buttons: buttons(presentation), onEscape: cancel,
                   accessory: presentation.showsProgress ? AnyView(ProgressView().controlSize(.small)) : nil) {
            if !presentation.message.isEmpty {
                PromptCardBodyText(text: presentation.message, palette: palette)
                    .padding(.top, t.bodyGap)
            }
            if !presentation.rows.isEmpty {
                rows(presentation.rows)
                    .padding(.top, t.controlGap)
            }
            if let code = presentation.qrCode {
                WebAuthnQRCodeView(text: code)
                    .frame(maxWidth: .infinity)
                    .padding(.top, t.controlGap)
            }
            switch presentation.input {
            case .none:
                EmptyView()
            case .pin:
                ModalCardTextField(placeholder: "PIN", text: $pin, palette: palette,
                                   identifier: "openarc.dialog.webauthn.pin", isSecure: true, onSubmit: accept)
                    .padding(.top, t.controlGap)
            case .newPIN:
                VStack(alignment: .leading, spacing: t.fieldSpacing) {
                    ModalCardTextField(placeholder: "New PIN", text: $pin, palette: palette,
                                       identifier: "openarc.dialog.webauthn.newPIN", isSecure: true, onSubmit: accept)
                    ModalCardTextField(placeholder: "Confirm PIN", text: $confirmation, palette: palette,
                                       identifier: "openarc.dialog.webauthn.confirmPIN", isSecure: true,
                                       focusesOnAppear: false, onSubmit: accept)
                }
                .padding(.top, t.controlGap)
            }
            if let error = localError ?? presentation.errorText {
                Text(error)
                    .font(Typography.dialogButton.font)
                    .foregroundStyle(palette.dialogDestructiveFill.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, t.fieldSpacing)
            }
        }
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

    /// "Use Another Method" at the left, Cancel (ESC) and the main button (↵) at the right; with
    /// no main button, Cancel is the only keyed one.
    private func buttons(_ presentation: WebAuthnPresentation) -> [PromptCardButtonItem] {
        var items: [PromptCardButtonItem] = []
        if presentation.showsChooseAnotherMethod {
            items.append(PromptCardButtonItem(title: "Use Another Method", role: .plain, isEnabled: !state.isBusy) {
                dialog.session.send(.chooseAnotherMethod)
            })
        }
        items.append(PromptCardButtonItem(title: "Cancel", role: .cancel, action: cancel))
        if let title = presentation.acceptTitle {
            items.append(PromptCardButtonItem(title: title, role: .primary,
                                              isEnabled: !state.isBusy && presentation.acceptEnabled, action: accept))
        }
        return items
    }

    private func cancel() {
        center.answer(dialog.id, with: .webAuthn(.cancel))
    }

    private func rows(_ rows: [WebAuthnPresentation.Row]) -> some View {
        let t = PromptCardTokens.self
        let ink = PromptCardInk.title(palette).swiftUI
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Button {
                    if let command = WebAuthnPresentation.rowCommand(for: state, row: index) {
                        dialog.session.send(command)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol)
                            .frame(width: 20)
                            .foregroundStyle(ink.opacity(0.6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(Typography.dialogButton.font.weight(.medium))
                                .foregroundStyle(ink)
                            if !row.detail.isEmpty {
                                Text(row.detail)
                                    .font(Typography.dialogButton.font)
                                    .foregroundStyle(ink.opacity(0.6))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                .accessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: t.choiceListCornerRadius, style: .continuous)
                .fill(palette.isDark ? Color.white.opacity(0.06) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: t.choiceListCornerRadius, style: .continuous)
                .strokeBorder(palette.dialogInk.swiftUI.opacity(0.12), lineWidth: 1)
        )
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

/// Plan B155: the hybrid QR code, drawn with CoreImage's QR generator. Black modules on a white
/// quiet zone in both appearances, so phone cameras read it in dark mode too. Size inferred
/// (Chromium's sheet draws a code of about this size); Arc's is unknown.
struct WebAuthnQRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: Self.side, height: Self.side)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
                .accessibilityLabel("QR code")
                .accessibilityIdentifier("openarc.dialog.webauthn.qrcode")
        }
    }

    /// Points. Inferred from Chromium's sheet; Arc's size is unknown.
    static let side: CGFloat = 176

    /// The QR code with one pixel per module (drawn scaled without smoothing), or nil when
    /// CoreImage cannot encode `text`. Error correction "M": caBLE codes are long.
    static func image(for text: String) -> CGImage? {
        guard let data = text.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }
}
