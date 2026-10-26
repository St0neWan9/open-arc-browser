// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACExtensions: a profile's extensions. Skeleton for plan C14 (install from the Web Store,
// toolbar actions in the Site Control Center, popups). Spec: [01 §Extensions] observed
// "Add Extension…" and "Manage Extensions…"; [06 §12] observed the Site Control Center
// "Extensions" section with an add button and "Manage" when extensions exist.
//
// Maps to: `SiteExtensionAction` and `SiteSettingsProvider.runExtensionAction` in
// app/Sources/OpenArcShell/SiteControls/SiteSettingsProvider.swift; the rest is proposed as
// `EngineExtensions` (SWIFT_PROTOCOL_CHANGES.md §9).
// The Chromium side (kept from `//chrome`, decision Q7): `ExtensionService` / `ExtensionRegistry`,
// the Web Store installer (webstore_private API on chromewebstore.google.com), and
// `ExtensionActionManager`. Chrome's toolbar (`ExtensionsToolbarContainer`) is replaced: action
// icons are given to the shell as data, and popups are hosted in a view the shell places in its
// own popover. Install confirmation (Chrome's install dialog) is a request to the shell.
//
// Skeleton: enough for the Site Control Center list and the Add / Manage menu items. Permissions
// changes, side panels and the extension context menu are settled in C14. "Manage Extensions…"
// opens chrome://extensions in a tab until a native page exists.

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class NSView;
@class OACProfile;
@class OACTab;
@class OACExtensions;

/// One installed extension, with its action state for a given tab when one was asked for.
/// Maps to `SiteExtensionAction` (id, name; the icon replaces the SF Symbol placeholder).
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACExtensionInfo : NSObject <NSCopying>
/// The 32-character extension id (`SiteExtensionAction.id`).
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL allowedInIncognito;
/// The action icon (for the tab, if the info was read for one) at 32 px, PNG.
@property (nonatomic, readonly, copy, nullable) NSData *iconPNGData;
/// Badge text and tooltip of the action for the tab; empty when none.
@property (nonatomic, readonly, copy) NSString *badgeText;
@property (nonatomic, readonly, copy) NSString *actionTitle;
/// The action is enabled on that tab (page actions may be disabled per page).
@property (nonatomic, readonly) BOOL isActionEnabled;
/// Clicking the action opens a popup (else it sends a click event to the extension).
@property (nonatomic, readonly) BOOL hasPopup;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Install confirmation for a Web Store install. Answer once; dropping it unanswered cancels.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensionInstallRequest : NSObject
@property (nonatomic, readonly, copy) NSString *extensionName;
@property (nonatomic, readonly, copy, nullable) NSData *iconPNGData;
/// Human-readable permission warnings from Chromium ("Read and change all your data on all
/// websites").
@property (nonatomic, readonly, copy) NSArray<NSString *> *permissionWarnings;
- (void)approve;
- (void)cancel;
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
/// The extension wants its popup shown (action clicked, or `chrome.action.openPopup()`). The shell
/// puts `popupView` in a popover anchored to the Site Control Center row (inferred: where the
/// popup appears is not in the spec). The view resizes itself to the popup's content; observe its
/// frame. Calling `-closePopup` or closing the popover ends it.
- (void)extensions:(OACExtensions *)extensions showPopupView:(NSView *)popupView forExtension:(NSString *)extensionIdentifier tab:(OACTab *)tab;
- (void)extensions:(OACExtensions *)extensions didClosePopupForExtension:(NSString *)extensionIdentifier;
@end

OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACExtensions : NSObject

@property (nonatomic, readonly, weak, nullable) OACProfile *profile;
@property (nonatomic, weak, nullable) id<OACExtensionsDelegate> delegate;

/// Installed extensions, without per-tab action state.
@property (nonatomic, readonly, copy) NSArray<OACExtensionInfo *> *installedExtensions;

/// Extensions with an action on `tab`, with that tab's icon, badge and enabled state. The Site
/// Control Center "Extensions" section (`SiteSettingsState.extensions`).
- (NSArray<OACExtensionInfo *> *)actionsForTab:(OACTab *)tab;

/// Runs an extension's action on `tab` (`SiteSettingsProvider.runExtensionAction`). Opens the popup
/// through the delegate when the action has one.
- (void)runActionOfExtension:(NSString *)extensionIdentifier onTab:(OACTab *)tab;
- (void)closePopup;

/// Installs from the Web Store by id (the store page's "Add to Open Arc" button goes through the
/// same path via the webstore private API).
- (void)installFromWebStoreWithIdentifier:(NSString *)extensionIdentifier
                        completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
/// Loads an unpacked extension from a folder (developer mode in chrome://extensions).
- (void)loadUnpackedFromURL:(NSURL *)folderURL completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)setEnabled:(BOOL)enabled forExtension:(NSString *)extensionIdentifier;
- (void)uninstallExtension:(NSString *)extensionIdentifier;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
