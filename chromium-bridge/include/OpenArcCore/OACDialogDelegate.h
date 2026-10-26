// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACDialogDelegate: dialogs and prompts the shell draws itself (plan C12).
//
// Maps to: nothing in OpenArcEngine yet. The proposed Swift side is `EngineDialogRequest` and a
// `BrowserTab.dialogRequests()` stream (SWIFT_PROTOCOL_CHANGES.md §3). C12 acceptance: "each
// dialog has a SwiftUI view; behavior from Chromium".
//
// Why shell-drawn (README §Keeping //chrome without its UI): Chrome draws these with Views
// (`JavaScriptTabModalDialogViewViews`, the permission bubble, the login view). We keep the
// `//chrome` controllers that decide WHEN to ask and WHAT to remember (the JavaScript dialog
// manager's suppression rules, `permissions::PermissionRequestManager`, the login handler, the
// external protocol handler's policy) and replace only the drawing: the bridge implements the
// controller's UI hook and forwards a request object here.
//
// Request objects, one per prompt:
// - Answer exactly once with one of the request's reply methods; later replies are ignored.
// - The engine may cancel a request on its own (the tab navigated, closed, or the page withdrew
//   the request). The bridge then calls `-tab:didCancelDialogRequest:` (optional) and
//   `isFinished` turns YES; the shell removes its view.
// - Dropping the last reference to an unanswered request answers it with its default (alert:
//   dismissed, confirm: cancel, prompt: nil, permission: dismissed (not remembered), auth: cancel,
//   file chooser: cancel, external protocol: block), so a page never hangs.
// - With no dialog delegate, or when the delegate method returns NO, the default answer is used
//   right away.
//
// The look of every one of these dialogs is not in docs/arc-spec (unknown); C12 designs them.
//
// As built in C12: JavaScript dialogs come from the tab's JavaScriptDialogManager; permission
// prompts from `permissions::PermissionRequestManager` (its prompt view is the bridge's;
// getUserMedia reaches it through `MediaCaptureDevicesDispatcher`); HTTP auth from //chrome's
// HTTP auth flow (`LoginTabHelper` / `LoginHandler`, our view); file choosers from the tab's
// `WebContentsDelegate::RunFileChooser` (`<input type=file>`; the File System Access pickers keep
// Chromium's native macOS panel); external protocols from `ExternalProtocolHandler` after its
// policy decided to ask.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Base

/// Common part of every request.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACDialogRequest : NSObject
/// The tab that asked. nil once that tab closed (the request is cancelled then).
@property (nonatomic, readonly, weak, nullable) OACTab *tab;
/// The requesting origin, shown in the dialog ("example.com wants to…"). nil for opaque origins
/// (data: URLs, sandboxed frames); the shell then shows "This page".
@property (nonatomic, readonly, copy, nullable) OACOrigin *origin;
/// The request comes from a cross-origin iframe of `tab`'s page.
@property (nonatomic, readonly) BOOL isFromSubframe;
/// YES once answered or cancelled.
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
/// Answers with the request's default (see the file comment).
- (void)cancel;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// MARK: - JavaScript dialogs

typedef NS_ENUM(NSInteger, OACJavaScriptDialogKind) {
    OACJavaScriptDialogKindAlert = 0,
    OACJavaScriptDialogKindConfirm = 1,
    OACJavaScriptDialogKindPrompt = 2,
    /// "Leave site? Changes you made may not be saved." (beforeunload). `message` is Chromium's
    /// localized text: pages cannot set it.
    OACJavaScriptDialogKindBeforeUnload = 3,
};

/// alert(), confirm(), prompt() and the beforeunload prompt. Tab-modal: the shell draws it over
/// the tab's web panel only. Chromium's rules stay in charge: dialogs from a background tab wait
/// until it is shown, and repeated dialogs offer "Prevent this page from creating additional
/// dialogs" (`showsSuppressOption`).
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACJavaScriptDialogRequest : OACDialogRequest
@property (nonatomic, readonly) OACJavaScriptDialogKind kind;
@property (nonatomic, readonly, copy) NSString *message;
/// prompt() default text; empty otherwise.
@property (nonatomic, readonly, copy) NSString *defaultPromptText;
/// For beforeunload: YES when it is a reload rather than leaving the page (button text differs).
@property (nonatomic, readonly) BOOL isReload;
/// Offer the "prevent additional dialogs" checkbox.
@property (nonatomic, readonly) BOOL showsSuppressOption;

/// OK / Leave. `promptText` is used for prompt() only. `suppressFurtherDialogs` from the checkbox.
- (void)acceptWithPromptText:(nullable NSString *)promptText suppressFurtherDialogs:(BOOL)suppressFurtherDialogs
    NS_SWIFT_NAME(accept(promptText:suppressFurtherDialogs:));
/// Cancel / Stay (alert: same as dismissing).
- (void)dismissSuppressingFurtherDialogs:(BOOL)suppressFurtherDialogs NS_SWIFT_NAME(dismiss(suppressFurtherDialogs:));
@end

// MARK: - HTTP authentication

/// HTTP Basic/Digest auth and proxy auth. Chromium's login handler fills saved credentials from the
/// password manager first (C13); `suggestedUsername` comes from there.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACAuthenticationRequest : OACDialogRequest
/// The authentication realm string the server sent (shown as-is, untrusted).
@property (nonatomic, readonly, copy) NSString *realm;
/// The server or proxy host and port that asks.
@property (nonatomic, readonly, copy) NSString *challengerHostPort;
/// A proxy asks (407), not the server. (Not `isProxy`, which is NSObject's.)
@property (nonatomic, readonly) BOOL isProxyChallenge;
/// The connection is not encrypted (show a warning in the dialog).
@property (nonatomic, readonly) BOOL isInsecureConnection;
@property (nonatomic, readonly, copy, nullable) NSString *suggestedUsername;

- (void)proceedWithUsername:(NSString *)username password:(NSString *)password;
@end

// MARK: - Permissions

/// Permission kinds the shell can prompt for. The first four match `SitePermissionKind` in
/// app/Sources/OpenArcShell/SiteControls/SiteSettingsProvider.swift (camera, microphone, location,
/// notifications); the rest are proposed additions (SWIFT_PROTOCOL_CHANGES.md §5).
typedef NS_ENUM(NSInteger, OACPermissionKind) {
    OACPermissionKindCamera = 0,
    OACPermissionKindMicrophone = 1,
    OACPermissionKindLocation = 2,
    OACPermissionKindNotifications = 3,
    OACPermissionKindClipboardRead = 4,
    OACPermissionKindMIDI = 5,
    OACPermissionKindStorageAccess = 6,
    OACPermissionKindScreenWakeLock = 7,
    OACPermissionKindMultipleDownloads = 8,
    OACPermissionKindLocalFonts = 9,
    OACPermissionKindWindowManagement = 10,
    OACPermissionKindIdleDetection = 11,
    OACPermissionKindProtectedMedia = 12,
};

/// A permission prompt. Chromium groups requests that arrive together (camera + microphone from
/// one getUserMedia call) into one prompt, so `kinds` can hold more than one.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACPermissionRequest : OACDialogRequest
/// `OACPermissionKind` values as NSNumbers, in Chromium's display order.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *kinds NS_REFINED_FOR_SWIFT;
/// The request comes from a user gesture (prompts without one may be shown quietly).
@property (nonatomic, readonly) BOOL hasUserGesture;
/// Every kind supports a one-time grant (Chromium's "Allow this time": camera, microphone,
/// location). NO: `allowRemembering:NO` stores "allow" like YES does.
@property (nonatomic, readonly) BOOL supportsAllowingOnce;

/// Allow. `remember` NO: allow this time only (until the page is closed); YES: store "allow" for
/// the origin in the profile's site settings.
- (void)allowRemembering:(BOOL)remember NS_SWIFT_NAME(allow(remembering:));
/// Block. Chromium stores "block" for the origin either way (its prompt has no one-time block).
- (void)denyRemembering:(BOOL)remember NS_SWIFT_NAME(deny(remembering:));
/// Closed without a decision (Chromium counts dismissals toward its auto-block heuristic).
- (void)dismiss;
@end

// MARK: - File chooser

typedef NS_ENUM(NSInteger, OACFileChooserMode) {
    OACFileChooserModeOpen = 0,
    OACFileChooserModeOpenMultiple = 1,
    OACFileChooserModeOpenFolder = 2,
    /// showSaveFilePicker().
    OACFileChooserModeSave = 3,
};

/// `<input type=file>` and the File System Access pickers. The shell shows an `NSOpenPanel` /
/// `NSSavePanel` as a sheet on the tab's window.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACFileChooserRequest : OACDialogRequest
@property (nonatomic, readonly) OACFileChooserMode mode;
/// Uniform type identifiers derived from the `accept` attribute; empty: any file.
@property (nonatomic, readonly, copy) NSArray<NSString *> *acceptedTypeIdentifiers;
/// Suggested file name or starting folder, if the page gave one.
@property (nonatomic, readonly, copy, nullable) NSURL *defaultURL;
/// `capture` attribute set (no camera capture UI on macOS: treated as a normal open panel).
@property (nonatomic, readonly) BOOL wantsCapture;

- (void)selectURLs:(NSArray<NSURL *> *)fileURLs;
@end

// MARK: - External protocol

/// A navigation to a scheme Chromium cannot handle (mailto:, zoommtg:, slack:…). Chromium's policy
/// (per-origin "always allow" memory, blocked schemes, user gesture rules) runs first; this request
/// only appears when Chromium would show its "Open <App>?" dialog.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExternalProtocolRequest : OACDialogRequest
@property (nonatomic, readonly, copy) NSURL *URL;
/// Display name of the app that handles the scheme (from LaunchServices); nil if none.
@property (nonatomic, readonly, copy, nullable) NSString *handlerApplicationName;
/// Bundle URL of that app, for its icon.
@property (nonatomic, readonly, copy, nullable) NSURL *handlerApplicationURL;
@property (nonatomic, readonly) BOOL hasUserGesture;
/// Chromium may remember "always allow" for this origin (a potentially trustworthy origin, and the
/// policy allows the checkbox). NO: `rememberForOrigin` is ignored.
@property (nonatomic, readonly) BOOL canRememberForOrigin;

/// Opens the URL in the handler app. `rememberForOrigin` stores "always allow" for this scheme on
/// the requesting origin.
- (void)openRememberingForOrigin:(BOOL)rememberForOrigin NS_SWIFT_NAME(open(rememberingForOrigin:));
@end

// MARK: - Delegate

@class OACPasswordSavePrompt;
@class OACAutofillPopup;

/// Implemented by the shell. Each method returns YES when the shell will show UI and answer the
/// request later, NO to let the bridge use the default answer right away.
NS_SWIFT_UI_ACTOR
@protocol OACDialogDelegate <NSObject>
@optional
- (BOOL)tab:(OACTab *)tab runJavaScriptDialog:(OACJavaScriptDialogRequest *)request;
- (BOOL)tab:(OACTab *)tab requestAuthentication:(OACAuthenticationRequest *)request;
- (BOOL)tab:(OACTab *)tab requestPermission:(OACPermissionRequest *)request;
- (BOOL)tab:(OACTab *)tab runFileChooser:(OACFileChooserRequest *)request;
- (BOOL)tab:(OACTab *)tab openExternalProtocol:(OACExternalProtocolRequest *)request;
/// Password manager save / update prompt (plan C13, OACAutofill.h).
- (BOOL)tab:(OACTab *)tab offerToSavePassword:(OACPasswordSavePrompt *)prompt
    NS_SWIFT_NAME(tab(_:offerToSavePassword:));
/// Autofill dropdown for the focused field (plan C13, OACAutofill.h).
- (BOOL)tab:(OACTab *)tab showAutofillPopup:(OACAutofillPopup *)popup
    NS_SWIFT_NAME(tab(_:showAutofillPopup:));
/// The dropdown's rows or highlighted row changed (the user typed, or pressed ↑ / ↓).
- (void)tab:(OACTab *)tab didUpdateAutofillPopup:(OACAutofillPopup *)popup
    NS_SWIFT_NAME(tab(_:didUpdateAutofillPopup:));

/// The engine cancelled an unanswered request (navigation, tab closed, page withdrew it).
- (void)tab:(OACTab *)tab didCancelDialogRequest:(OACDialogRequest *)request;
@end

NS_ASSUME_NONNULL_END
