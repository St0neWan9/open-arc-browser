// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACExtensions: a profile's extensions (plan C14). Spec: [01 §Extensions] observed
// "Add Extension…" and "Manage Extensions…"; [06 §12] observed the Site Control Center
// "Extensions" section with an add button and "Manage" when extensions exist; [06 §17.2] observed
// that the web toolbar has no extension buttons (they are all in the Site Control Center).
//
// Maps to: `EngineExtensions` (app/Sources/OpenArcEngine/EngineServices.swift), the Site Control
// Center's `SiteExtensionAction`, `ExtensionPopup` and the `.extensionInstall` dialog request.
//
// The Chromium side (kept from `//chrome`, decision Q7): the profile's `ExtensionService` /
// `ExtensionRegistry` / `ExtensionRegistrar`, the Web Store installer (the store page's
// webstorePrivate API on chromewebstore.google.com, in a normal tab), `UnpackedInstaller`,
// `ExtensionActionManager` / `ExtensionActionRunner` and an `ExtensionViewHost` per popup. Chrome's
// toolbar (`ExtensionsToolbarContainer`) and its Views dialogs are replaced: action icons reach the
// shell as data, a popup's page is a view the shell places in its own bubble, and install
// confirmations (Chrome's install dialog, an Open Arc hook in `ExtensionInstallPrompt`) are
// requests the shell answers.
//
// Keyboard commands (plan C26): the manifest's `commands` work while a tab of the profile has the
// keyboard, as in Chrome: a named command sends `commands.onCommand` with that tab (and grants
// activeTab when the extension asks for it); `_execute_action` runs the action on the tab and its
// popup comes to the delegate (`-extensions:didOpenPopup:onTab:`). Shortcuts are set in
// chrome://extensions/shortcuts. Global (system-wide) commands are not registered.
//
// Runtime errors (plan C26): with developer mode on, Chromium's error console collects them for
// every extension (all of an unpacked one's, and errors of others once their "Collect errors"
// switch is on); chrome://extensions lists them under "Errors". `OACExtensionInfo.errorCount`
// counts them.
//
// Tabs and windows (plan C31): `chrome.tabs.create`, `chrome.windows.create` and
// `chrome.runtime.openOptionsPage` open in the shell. The engine makes the tab (the extension gets
// its id back) and hands it to `-[OACApplicationDelegate application:didRequestNewTab:]` as a
// request with pending contents and no opener; `windows.create` asks for a new window (or a popup).
// Moving tabs between windows, incognito windows and window ids other than the current one are
// errors for the extension.
//
// Windows (plan B126): the shell reports its windows (`OACExtensions.windows`, most recently
// focused first). `chrome.windows.get`, `getCurrent`, `getLastFocused` and `getAll` answer with
// them (id, focused, bounds, type normal or popup, their tabs); the tabs carry the window's id
// (`tab.windowId`, `tabs.query({windowId})`), and `tabs.query({currentWindow: true})` means the
// most recently focused window. A window belongs to one profile: an incognito window to the
// off-the-record profile only. Window events (`windows.onFocusChanged` …), `windows.update` and
// `windows.remove` are not covered.
//
// `chrome.action.openPopup()` (plan B125) opens the popup over the active tab of the most recently
// focused window, when that window is focused, and hands it to the delegate like a keyboard
// shortcut's popup (`-extensions:didOpenPopup:onTab:`); the call resolves once the popup's page
// loaded. It fails while another popup is open, as in Chrome.
//
// Not covered: side panels and the rest of `chrome.windows.*`: they fail as in a Chrome without
// windows. "Manage Extensions…" opens chrome://extensions in a tab until a native page exists.

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class NSView;
@class OACProfile;
@class OACTab;
@class OACExtensions;
@class OACExtensionPopup;

/// One installed extension, with its action state for a given tab when one was asked for.
/// Maps to `EngineExtensionInfo` and the Site Control Center's `SiteExtensionAction`.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACExtensionInfo : NSObject <NSCopying>
/// The 32-character extension id (`SiteExtensionAction.id`).
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL allowedInIncognito;
/// Loaded from a folder (developer mode), not from the Web Store.
@property (nonatomic, readonly, getter=isUnpacked) BOOL unpacked;
/// The action icon (for the tab, if the info was read for one) at 16 pt in 2x pixels (32 px), PNG.
/// For an extension without an action: its product icon. nil while it is still loading.
@property (nonatomic, readonly, copy, nullable) NSData *iconPNGData;
/// Badge text and tooltip of the action for the tab; empty when none.
@property (nonatomic, readonly, copy) NSString *badgeText;
@property (nonatomic, readonly, copy) NSString *actionTitle;
/// The action is enabled on that tab (page actions may be disabled per page).
@property (nonatomic, readonly) BOOL isActionEnabled;
/// Clicking the action opens a popup (else it sends a click event to the extension).
@property (nonatomic, readonly) BOOL hasPopup;
/// Runtime and manifest errors the error console holds for the extension (plan C26); 0 while
/// developer mode is off (the console then collects nothing).
@property (nonatomic, readonly) NSInteger errorCount;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Install confirmation (Chrome's install dialog): a Web Store install, a re-enable after a
/// permission increase, or `installFromWebStoreWithIdentifier:`. Answer once; dropping it
/// unanswered cancels the install.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensionInstallRequest : NSObject
/// The tab that asked (the Web Store page); nil when no tab did (`installFromWebStore…`). The
/// shell draws the confirmation over this tab.
@property (nonatomic, readonly, weak, nullable) OACTab *tab;
@property (nonatomic, readonly, copy) NSString *extensionIdentifier;
@property (nonatomic, readonly, copy) NSString *extensionName;
@property (nonatomic, readonly, copy, nullable) NSData *iconPNGData;
/// Chromium's localized texts for the dialog ("Add “uBlock Origin Lite”?", "Add extension",
/// "Cancel"). The shell may use its own wording.
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *acceptButtonTitle;
@property (nonatomic, readonly, copy) NSString *cancelButtonTitle;
/// Human-readable permission warnings from Chromium ("Read and change all your data on all
/// websites"), in Chromium's order. Empty when the extension asks for nothing that warns.
@property (nonatomic, readonly, copy) NSArray<NSString *> *permissionWarnings;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
- (void)approve;
- (void)cancel;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Popup events. Delivered on the main thread from a posted task (OACDefines.h).
NS_SWIFT_UI_ACTOR
@protocol OACExtensionPopupDelegate <NSObject>
@optional
/// The popup's page finished its first load: the shell shows the bubble now (Chrome does the same,
/// so a popup never shows half loaded).
- (void)extensionPopupDidLoad:(OACExtensionPopup *)popup;
/// The page laid out at `size` (points, within Chromium's popup limits 25×25…800×600). The shell
/// sizes its bubble to it; the view follows its container.
- (void)extensionPopup:(OACExtensionPopup *)popup didResizeTo:(CGSize)size;
/// Closed: by `-close`, by the page (`window.close()`, Escape), or because the extension or its
/// tab went away. The view is gone from the window afterwards.
- (void)extensionPopupDidClose:(OACExtensionPopup *)popup;
@end

/// An extension action's popup page (Chrome's `ExtensionViewHost` of type popup), shown by the
/// shell in a bubble anchored to the Site Control Center button (inferred: the spec records where
/// extensions live, not where their popups appear). One per profile at a time: opening another
/// closes the first.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensionPopup : NSObject
@property (nonatomic, readonly, copy) NSString *extensionIdentifier;
/// The tab the action ran on. nil once that tab closed (the popup closes with it).
@property (nonatomic, readonly, weak, nullable) OACTab *tab;
/// The popup page's view. The shell adds it to its bubble and keeps it at the bubble's size; nil
/// once closed.
@property (nonatomic, readonly, nullable) NSView *view;
/// The size the page asked for; CGSizeZero until the first layout.
@property (nonatomic, readonly) CGSize preferredSize;
@property (nonatomic, readonly) BOOL hasLoaded;
@property (nonatomic, readonly, getter=isClosed) BOOL closed;
@property (nonatomic, weak, nullable) id<OACExtensionPopupDelegate> delegate;
/// Gives the popup's page the keyboard (call once its bubble window is key).
- (void)focus;
- (void)close;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// One of the shell's windows as extensions see it (`chrome.windows`, plan B126). The shell makes
/// one per window it reports in `OACExtensions.windows`.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensionWindow : NSObject
/// Stable for the window's life: the bridge gives each identifier one Chromium window id.
@property (nonatomic, readonly, copy) NSUUID *identifier;
/// The profile the window's tabs belong to; an incognito window passes the off-the-record profile.
/// nil once the profile is gone (the window is then left out).
@property (nonatomic, readonly, weak, nullable) OACProfile *profile;
/// The window is the key window.
@property (nonatomic, getter=isFocused) BOOL focused;
/// A popup window (`type: "popup"`), else a normal one.
@property (nonatomic, getter=isPopup) BOOL popup;
/// The window's frame in AppKit screen coordinates (points, origin at the bottom left of the main
/// screen), as `NSWindow.frame`. Extensions get it flipped, as Chrome reports bounds.
@property (nonatomic) CGRect frame;
/// The window's tabs in its order. Each tab belongs to one window: a tab listed by several takes
/// the id of the first one in `OACExtensions.windows`. Held weakly: closed tabs drop out.
@property (nonatomic, copy) NSArray<OACTab *> *tabs;
/// The tabs it shows (the selected tab, or the panes of a split view); a subset of `tabs`.
@property (nonatomic, copy) NSArray<OACTab *> *activeTabs;
- (instancetype)initWithIdentifier:(NSUUID *)identifier profile:(OACProfile *)profile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
@protocol OACExtensionsDelegate <NSObject>
@optional
/// The installed set or an extension's state changed.
- (void)extensionsDidChange:(OACExtensions *)extensions;
/// An action's icon, badge or enabled state changed for `tab` (nil: every tab).
- (void)extensions:(OACExtensions *)extensions didUpdateActionOfExtension:(NSString *)extensionIdentifier tab:(nullable OACTab *)tab;
/// Chromium wants to confirm an install. Return YES to show UI and answer later, NO to cancel.
- (BOOL)extensions:(OACExtensions *)extensions confirmInstall:(OACExtensionInstallRequest *)request;
/// An extension opened its popup on `tab` without a call to `-runActionOfExtension:onTab:`: its
/// `_execute_action` shortcut (plan C26) or `chrome.action.openPopup()` (plan B125). The shell
/// shows it as after `-runActionOfExtension:onTab:`. Without this method the popup is closed (and
/// `openPopup()` fails).
- (void)extensions:(OACExtensions *)extensions didOpenPopup:(OACExtensionPopup *)popup onTab:(OACTab *)tab;
/// An extension's error count changed (plan C26, `OACExtensionInfo.errorCount`).
- (void)extensions:(OACExtensions *)extensions didChangeErrorsOfExtension:(NSString *)extensionIdentifier;
@end

/// A profile's extensions. Off-the-record profiles share their original profile's object; only
/// extensions allowed in incognito have actions on off-the-record tabs.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensions : NSObject

@property (nonatomic, readonly, weak, nullable) OACProfile *profile;
@property (nonatomic, weak, nullable) id<OACExtensionsDelegate> delegate;

/// Installed extensions the user manages (component extensions such as the PDF viewer are left
/// out), without per-tab action state, in installation order.
@property (nonatomic, readonly, copy) NSArray<OACExtensionInfo *> *installedExtensions;

/// Enabled extensions with a toolbar action on `tab`, with that tab's icon, badge and enabled
/// state. The Site Control Center "Extensions" section (`SiteSettingsState.extensions`).
- (NSArray<OACExtensionInfo *> *)actionsForTab:(OACTab *)tab;

/// Runs an extension's action on `tab`, as a click on its toolbar button does in Chrome: grants
/// the extension activeTab on the tab, then opens its popup or sends `action.onClicked`. Returns
/// the popup (not shown yet: see `OACExtensionPopupDelegate`), or nil when there is none.
- (nullable OACExtensionPopup *)runActionOfExtension:(NSString *)extensionIdentifier onTab:(OACTab *)tab;
/// The open popup, if any.
@property (nonatomic, readonly, nullable) OACExtensionPopup *popup;

/// The shell's windows for every profile, most recently focused first (plan B126). The shell sets
/// the whole list again whenever a window opens, closes, gains or loses focus, moves, or changes
/// its tabs or the tab it shows. Empty until then: `chrome.windows.get*` finds no window and every
/// tab counts as in the current window.
@property (class, nonatomic, copy) NSArray<OACExtensionWindow *> *windows;

/// Installs from the Web Store by id. Chromium asks through `-extensions:confirmInstall:` (with no
/// tab). The store page's own "Add to …" button takes the store's install flow instead.
- (void)installFromWebStoreWithIdentifier:(NSString *)extensionIdentifier
                        completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
/// Loads an unpacked extension from a folder, as "Load unpacked" in chrome://extensions does;
/// turns developer mode on (Chromium disables unpacked extensions without it). The handler gets the
/// extension id, or an error with Chromium's message.
- (void)loadUnpackedFromURL:(NSURL *)folderURL
          completionHandler:(void (^)(NSString *_Nullable extensionIdentifier, NSError *_Nullable error))completionHandler;
- (void)setEnabled:(BOOL)enabled forExtension:(NSString *)extensionIdentifier;
- (void)uninstallExtension:(NSString *)extensionIdentifier;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
