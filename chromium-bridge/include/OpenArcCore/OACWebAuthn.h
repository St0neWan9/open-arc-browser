// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The passkey / security-key (WebAuthn) dialog, drawn by the shell (plan C21).
//
// Maps to: `EngineDialogRequest.webAuthn` (app/Sources/OpenArcEngine/DialogRequests.swift).
//
// Why shell-drawn (README §Keeping //chrome without its UI): Chrome draws its WebAuthn dialog with
// Views as a tab-modal sheet of a `Browser` window. We keep //chrome's request flow (which
// authenticators exist, which step comes next, PIN entry, account choice, errors) and replace only
// its view: an Open Arc hook in //chrome hands the flow's model to the bridge, which describes the
// current step here and forwards the user's choices back. The flow moves through several steps
// while one request is open (choose a method, touch the security key, enter its PIN, pick an
// account…); each change comes as `-tab:didUpdateWebAuthnDialog:` on the same object.
//
// What is supported:
// - Security keys (USB / NFC readers that appear as USB HID; FIDO2 with PIN and fingerprint
//   enrollment, and U2F).
// - Passkeys stored on this Mac in the app's own keychain access group
//   (<team id>.<bundle id>.webauthn), protected by Touch ID or the login password. They need the
//   app's `keychain-access-groups` entitlement (a Developer ID build with a matching provisioning
//   profile, scripts/make-app.sh); without it the engine offers security keys only. During a
//   passkey operation macOS shows its own Touch ID / password prompt and this dialog closes.
// - iCloud Keychain passkeys (Apple's Passwords app and other passkey provider apps; plan B130):
//   offered only when the app is signed with Apple's restricted
//   `com.apple.developer.web-browser.public-key-credential` entitlement (scripts/make-app.sh adds
//   it when the provisioning profile allows it) and the tab is in a window. Without the
//   entitlement the engine never offers them. Choosing one hands over to macOS's own passkey
//   sheet (first: its "Passkeys Access for Web Browsers" consent), and this dialog closes.
// Not supported:
// - Phones and tablets as security keys (hybrid / caBLE, needs Bluetooth and the QR flow); the
//   bridge leaves that method out.
// - Google Password Manager passkeys (need a signed-in Google account).
//
// The look is not in docs/arc-spec (00 §A records the dialog exists; style unknown).

#import <OpenArcCore/OACDialogDelegate.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OACWebAuthnOperation) {
    /// `navigator.credentials.create()`: make a new passkey.
    OACWebAuthnOperationCreate = 0,
    /// `navigator.credentials.get()`: sign in with an existing passkey.
    OACWebAuthnOperationSignIn = 1,
};

typedef NS_ENUM(NSInteger, OACWebAuthnStep) {
    /// Choose how to continue (`mechanisms`).
    OACWebAuthnStepChooseMethod = 0,
    /// Confirm the single most likely method (`mechanisms[priorityMechanismIndex]`); accept goes on.
    OACWebAuthnStepConfirmMethod = 1,
    /// Insert the security key and touch it (no button; the key answers).
    OACWebAuthnStepSecurityKey = 2,
    /// Enter the security key's PIN (`-providePIN:`); `pinError`, `pinAttemptsRemaining`.
    OACWebAuthnStepEnterPIN = 3,
    /// The security key has no PIN yet: choose one (the shell asks twice and compares).
    OACWebAuthnStepSetPIN = 4,
    /// The security key requires a new PIN (the shell asks twice and compares).
    OACWebAuthnStepChangePIN = 5,
    /// Touch the security key again (after the PIN).
    OACWebAuthnStepTouchAgain = 6,
    /// Fingerprint enrollment on the security key: touch the sensor (`bioSamplesRemaining`);
    /// accept when done.
    OACWebAuthnStepFingerprintEnrollment = 7,
    /// The key's fingerprint check failed; try again on the key (no button).
    OACWebAuthnStepRetryVerification = 8,
    /// Confirm storing sign-in data on the security key; accept goes on.
    OACWebAuthnStepConfirmSecurityKeyStorage = 9,
    /// Choose the account to sign in with (`accounts`, `-selectAccountAtIndex:`).
    OACWebAuthnStepChooseAccount = 10,
    /// Confirm creating a passkey on this Mac; accept goes on (macOS then asks for Touch ID or the
    /// password).
    OACWebAuthnStepCreatePasskey = 11,
    /// A private window: the passkey outlives it. Accept goes on.
    OACWebAuthnStepPrivateWindowWarning = 12,
    /// The request failed (`errorKind`); accept retries when `canRetry`.
    OACWebAuthnStepError = 13,
};

typedef NS_ENUM(NSInteger, OACWebAuthnErrorKind) {
    OACWebAuthnErrorKindNone = 0,
    /// The request timed out.
    OACWebAuthnErrorKindTimedOut = 1,
    /// The security key holds no passkey for this site.
    OACWebAuthnErrorKindKeyNotRegistered = 2,
    /// The security key already holds a passkey for this account.
    OACWebAuthnErrorKindKeyAlreadyRegistered = 3,
    /// No passkey for this site on this Mac.
    OACWebAuthnErrorKindNoPasskeys = 4,
    /// Nothing can answer this request (no platform passkeys, no security key support).
    OACWebAuthnErrorKindNoMethods = 5,
    /// Too many wrong PINs: remove and reinsert the key.
    OACWebAuthnErrorKindPINTemporarilyLocked = 6,
    /// Too many wrong PINs: the key must be reset.
    OACWebAuthnErrorKindPINLocked = 7,
    /// The key was removed during PIN entry.
    OACWebAuthnErrorKindKeyRemoved = 8,
    /// The key lacks a feature the site needs.
    OACWebAuthnErrorKindMissingCapability = 9,
    /// The key has no room for another passkey.
    OACWebAuthnErrorKindStorageFull = 10,
    /// A method this app does not support (phone, Bluetooth, cloud passkeys).
    OACWebAuthnErrorKindUnsupported = 11,
    /// Any other failure.
    OACWebAuthnErrorKindOther = 12,
};

typedef NS_ENUM(NSInteger, OACWebAuthnPINError) {
    OACWebAuthnPINErrorNone = 0,
    OACWebAuthnPINErrorWrongPIN = 1,
    OACWebAuthnPINErrorTooShort = 2,
    OACWebAuthnPINErrorInvalidCharacters = 3,
    OACWebAuthnPINErrorSameAsCurrent = 4,
    /// The key's fingerprint check is locked: enter the PIN instead.
    OACWebAuthnPINErrorFingerprintLocked = 5,
};

typedef NS_ENUM(NSInteger, OACWebAuthnMechanismKind) {
    /// A passkey for one account, stored on this Mac (`title`: the account).
    OACWebAuthnMechanismKindPasskeyOnThisMac = 0,
    /// Save or use a passkey on this Mac (no account yet).
    OACWebAuthnMechanismKindThisMac = 1,
    /// A USB / NFC security key.
    OACWebAuthnMechanismKindSecurityKey = 2,
    /// Anything else the engine offers.
    OACWebAuthnMechanismKindOther = 3,
    /// Save or use a passkey in iCloud Keychain (Passwords or another passkey app; no account
    /// yet). macOS shows its own sheet next.
    OACWebAuthnMechanismKindICloudKeychain = 4,
    /// A passkey for one account in iCloud Keychain (`title`: the account; `subtitle`: the app
    /// that holds it, may be empty). macOS shows its own sheet next.
    OACWebAuthnMechanismKindPasskeyInICloudKeychain = 5,
};

/// One way to continue (a row of the method list).
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACWebAuthnMechanism : NSObject
@property (nonatomic, readonly) OACWebAuthnMechanismKind kind;
/// Account name for passkeys; empty for the others (the shell names them).
@property (nonatomic, readonly, copy) NSString *title;
/// The account's display name, if different, or for iCloud Keychain passkeys the app that holds
/// the passkey (may be empty).
@property (nonatomic, readonly, copy) NSString *subtitle;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// One account to choose (`OACWebAuthnStepChooseAccount`).
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACWebAuthnAccount : NSObject
/// The account name (often an email address); may be empty.
@property (nonatomic, readonly, copy) NSString *name;
/// The display name; may be empty.
@property (nonatomic, readonly, copy) NSString *displayName;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// The WebAuthn dialog of one request. Tab-modal. Its properties change while it is open
/// (`-tab:didUpdateWebAuthnDialog:`). The actions do not finish the request; only `-cancel`
/// (the request's default when the shell drops it) does. The engine withdraws the request when the
/// flow hands over to macOS (Touch ID / password prompt), completes, or the tab navigates or closes;
/// a later step that needs the dialog again comes as a new request.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACWebAuthnDialog : OACDialogRequest
@property (nonatomic, readonly) OACWebAuthnOperation operation;
/// The relying party ("example.com").
@property (nonatomic, readonly, copy) NSString *relyingPartyID;
/// For `OACWebAuthnOperationCreate`: the account name the site creates a passkey for (may be empty).
@property (nonatomic, readonly, copy) NSString *userName;
@property (nonatomic, readonly) OACWebAuthnStep step;
/// The ways to continue (`OACWebAuthnStepChooseMethod`, `ConfirmMethod`).
@property (nonatomic, readonly, copy) NSArray<OACWebAuthnMechanism *> *mechanisms;
/// The method `OACWebAuthnStepConfirmMethod` asks about, or -1.
@property (nonatomic, readonly) NSInteger priorityMechanismIndex;
/// The accounts to choose from (`OACWebAuthnStepChooseAccount`).
@property (nonatomic, readonly, copy) NSArray<OACWebAuthnAccount *> *accounts;
/// "Use another method" (back to the method list) makes sense.
@property (nonatomic, readonly) BOOL canChooseAnotherMethod;
@property (nonatomic, readonly) OACWebAuthnErrorKind errorKind;
/// The error step offers to try again (`-accept`).
@property (nonatomic, readonly) BOOL canRetry;
@property (nonatomic, readonly) OACWebAuthnPINError pinError;
/// PIN attempts left before the key locks, or -1 when unknown.
@property (nonatomic, readonly) NSInteger pinAttemptsRemaining;
/// Minimum PIN length the key accepts (Unicode code points).
@property (nonatomic, readonly) NSInteger minimumPINLength;
/// Fingerprint enrollment progress: samples left and in total (-1 while unknown).
@property (nonatomic, readonly) NSInteger bioSamplesRemaining;
@property (nonatomic, readonly) NSInteger bioSamplesTotal;
/// The engine is busy (no input until the next update).
@property (nonatomic, readonly) BOOL isBusy;

/// The step's main button: continue, create, try again, done (see `OACWebAuthnStep`).
- (void)accept;
/// Chooses `mechanisms[index]`.
- (void)selectMechanismAtIndex:(NSInteger)index NS_SWIFT_NAME(selectMechanism(at:));
/// Chooses `accounts[index]`.
- (void)selectAccountAtIndex:(NSInteger)index NS_SWIFT_NAME(selectAccount(at:));
/// The PIN for `EnterPIN`, `SetPIN` or `ChangePIN` (the new PIN, already confirmed by the shell).
- (void)providePIN:(NSString *)PIN NS_SWIFT_NAME(providePIN(_:));
/// Back to the method list ("Use another method").
- (void)chooseAnotherMethod;
/// Cancels the request (the page gets NotAllowedError). The default answer.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
