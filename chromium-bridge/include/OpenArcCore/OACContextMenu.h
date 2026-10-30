// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACContextMenu: the web page's right-click menu, built by Chromium and drawn by the shell
// (plan B124).
//
// Spec: docs/arc-spec/05-surfaces.md §右键菜单, "网页内容右键菜单 (E29)" (observed): Arc's page, link,
// image, selection and editable-field menus, item by item, as a native NSMenu.
//
// Maps to: `PageContextMenu` and `TabEvent.contextMenuRequested` (app/Sources/OpenArcEngine/
// PageContextMenu.swift), wrapped by app/Sources/OpenArcChromium/ChromiumContextMenu.swift.
//
// How it works:
// - A right-click reaches the tab's `content::WebContentsDelegate::HandleContextMenu`. The bridge
//   builds Chromium's menu model for the click (`RenderViewContextMenu`, never shown by Chromium):
//   Chromium's own items for the target (page, link, image, selection, editable field), the
//   `chrome.contextMenus` items of the profile's extensions, spelling suggestions and the macOS
//   text services (Look Up, Speech, Writing Direction).
// - The bridge hands an `OACContextMenu` to `-tab:showContextMenu:`. It carries a snapshot of the
//   items (`items`, each with a `role` the shell can place) and what was clicked (`linkURL`,
//   `sourceURL`, `selectionText`, the editable flags).
// - The shell builds its own `NSMenu` in Arc's order from those items plus its own, and calls
//   `-popUpMenu:` once. Its items for Chromium's entries call `-performItemWithIdentifier:`, which
//   runs the command as Chromium's menu would (`chrome.contextMenus.onClicked` for an extension
//   item). Commands that need a Chrome browser window are run by the bridge another way (Reload,
//   Print, Inspect) or are left to the shell (see `OACContextMenuItemRole`).
// - Chromium may update an item while the menu is open (Copy Link to Highlight turns enabled once
//   its link is ready): `itemUpdateHandler` runs with the new item, on the main thread.
// - `-close` (or releasing the object) ends the menu; the page learns that its menu closed.
//
// A menu nobody shows costs nothing: with no delegate, or when the delegate returns NO, the bridge
// drops it and the page shows no menu.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACProfile.h>
#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OACContextMenuItemKind) {
    OACContextMenuItemKindCommand = 0,
    OACContextMenuItemKindCheckbox = 1,
    OACContextMenuItemKindSeparator = 2,
    OACContextMenuItemKindSubmenu = 3,
};

/// What a Chromium item does, so the shell can place it in its own order without knowing
/// Chromium's command numbers. `Other` is anything else Chromium offers (the shell may drop it).
typedef NS_ENUM(NSInteger, OACContextMenuItemRole) {
    OACContextMenuItemRoleOther = 0,
    // Page.
    OACContextMenuItemRoleBack = 1,
    OACContextMenuItemRoleForward = 2,
    OACContextMenuItemRoleReload = 3,
    /// Save As… Chromium's command saves through its own save dialog; the shell runs its Save Page
    /// As (format choice) instead.
    OACContextMenuItemRoleSavePage = 4,
    OACContextMenuItemRolePrint = 5,
    /// Cast… Chromium's cast dialog needs a Chrome browser window: not available.
    OACContextMenuItemRoleCast = 6,
    /// "Translate to <language>". Runs Chromium's translation (OACTranslation.h).
    OACContextMenuItemRoleTranslate = 7,
    OACContextMenuItemRoleViewSource = 8,
    OACContextMenuItemRoleInspect = 9,
    // Link.
    OACContextMenuItemRoleOpenLinkInNewTab = 10,
    OACContextMenuItemRoleOpenLinkInNewWindow = 11,
    /// Chromium would open the link in the tab's own profile; the shell opens an incognito window.
    OACContextMenuItemRoleOpenLinkInIncognito = 12,
    OACContextMenuItemRoleSaveLinkAs = 13,
    OACContextMenuItemRoleCopyLinkAddress = 14,
    // Selection.
    OACContextMenuItemRoleCopy = 15,
    /// Copy Link to Highlight (a URL with a text fragment). Disabled until Chromium made the link;
    /// an `itemUpdateHandler` call enables it.
    OACContextMenuItemRoleCopyLinkToHighlight = 16,
    /// "Search <engine> for “…”" with Chromium's default search engine. The shell uses its own
    /// engine instead.
    OACContextMenuItemRoleSearchWeb = 17,
    OACContextMenuItemRoleLookUp = 18,
    // Image.
    OACContextMenuItemRoleOpenImageInNewTab = 19,
    OACContextMenuItemRoleSaveImageAs = 20,
    OACContextMenuItemRoleCopyImage = 21,
    OACContextMenuItemRoleCopyImageAddress = 22,
    // Editable field.
    OACContextMenuItemRoleEmoji = 23,
    OACContextMenuItemRoleUndo = 24,
    OACContextMenuItemRoleRedo = 25,
    OACContextMenuItemRoleCut = 26,
    OACContextMenuItemRolePaste = 27,
    OACContextMenuItemRolePasteAndMatchStyle = 28,
    OACContextMenuItemRoleSelectAll = 29,
    OACContextMenuItemRoleLanguageSettings = 30,
    /// The Writing Direction submenu (Default, Left to Right, Right to Left).
    OACContextMenuItemRoleWritingDirection = 31,
    /// Spelling suggestions, Add to / Remove from Dictionary.
    OACContextMenuItemRoleSpelling = 32,
    /// Chromium's password import item (it opens Chrome's password manager page, which needs a
    /// Chrome browser window); the shell runs its own import.
    OACContextMenuItemRoleImportPasswords = 33,
    // Text services and extensions.
    /// The Speech submenu (Start Speaking, Stop Speaking).
    OACContextMenuItemRoleSpeech = 34,
    /// An item of an extension (`chrome.contextMenus`), or an extension's submenu of items.
    OACContextMenuItemRoleExtension = 35,
};

/// One item of a menu snapshot. Immutable.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACContextMenuItem : NSObject
/// Pass to `-performItemWithIdentifier:`. Unique within one menu; 0 for separators.
@property (nonatomic, readonly) NSInteger identifier;
@property (nonatomic, readonly) OACContextMenuItemKind kind;
@property (nonatomic, readonly) OACContextMenuItemRole role;
/// Chromium's localized title (empty for separators).
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isChecked) BOOL checked;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
/// For extension items: the extension's id.
@property (nonatomic, readonly, copy, nullable) NSString *extensionIdentifier;
/// The items of a submenu; empty otherwise.
@property (nonatomic, readonly, copy) NSArray<OACContextMenuItem *> *submenuItems;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// What the right-click hit.
typedef NS_ENUM(NSInteger, OACContextMenuMediaKind) {
    OACContextMenuMediaKindNone = 0,
    OACContextMenuMediaKindImage = 1,
    OACContextMenuMediaKindVideo = 2,
    OACContextMenuMediaKindAudio = 3,
    OACContextMenuMediaKindCanvas = 4,
    OACContextMenuMediaKindPlugin = 5,
    OACContextMenuMediaKindFile = 6,
};

/// The edit commands the focused field allows (Blink's edit flags).
typedef NS_OPTIONS(NSUInteger, OACContextMenuEditFlags) {
    OACContextMenuEditFlagCanUndo = 1 << 0,
    OACContextMenuEditFlagCanRedo = 1 << 1,
    OACContextMenuEditFlagCanCut = 1 << 2,
    OACContextMenuEditFlagCanCopy = 1 << 3,
    OACContextMenuEditFlagCanPaste = 1 << 4,
    OACContextMenuEditFlagCanSelectAll = 1 << 5,
};

/// One right-click menu of a tab. Main thread only.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACContextMenu : NSObject

@property (nonatomic, readonly, weak, nullable) OACTab *tab;
/// Chromium's items, in Chromium's order, as built for the click.
@property (nonatomic, readonly, copy) NSArray<OACContextMenuItem *> *items;

/// The link under the pointer, if any.
@property (nonatomic, readonly, copy, nullable) NSURL *linkURL;
/// The link's text.
@property (nonatomic, readonly, copy) NSString *linkText;
/// The image, video or audio source under the pointer, if any.
@property (nonatomic, readonly, copy, nullable) NSURL *sourceURL;
@property (nonatomic, readonly) OACContextMenuMediaKind mediaKind;
/// The image under the pointer has loaded (Copy Image works).
@property (nonatomic, readonly) BOOL hasImageContents;
/// The selected text (for an editable field, the word under the pointer that macOS selected).
@property (nonatomic, readonly, copy) NSString *selectionText;
@property (nonatomic, readonly, getter=isEditable) BOOL editable;
/// The field is a password field.
@property (nonatomic, readonly) BOOL isPasswordField;
@property (nonatomic, readonly) OACContextMenuEditFlags editFlags;
/// The page and the frame the click was in.
@property (nonatomic, readonly, copy, nullable) NSURL *pageURL;
@property (nonatomic, readonly, copy, nullable) NSURL *frameURL;
/// The click, in points, in the page's view with the origin at its top left (y down).
@property (nonatomic, readonly) CGPoint location;

/// Runs with an item Chromium changed while the menu is open (same identifier, new title or
/// enabled state). Main thread; may run while `-popUpMenu:` is still showing the menu.
@property (nonatomic, copy, nullable) void (^itemUpdateHandler)(OACContextMenuItem *item);

/// YES once closed.
@property (nonatomic, readonly, getter=isClosed) BOOL closed;

/// Shows `menu` (an `NSMenu`, typed `id` so this header stays free of AppKit) at the click, over
/// the page's view, and returns when it closed. Chromium's work (the page, the link for Copy Link
/// to Highlight) keeps running while it shows. macOS may add its own items (Services, AutoFill)
/// for the page's view. The menu closes (`-close`) on the next run loop turn, so an item's action
/// that AppKit sends as the menu ends can still call `-performItemWithIdentifier:`. At most once;
/// NO when closed already or when the tab has no view.
- (BOOL)popUpMenu:(id)menu;

/// Runs an item's command, as a click on it in Chromium's own menu would. Ignored for unknown,
/// disabled or submenu items and after `-close`.
- (void)performItemWithIdentifier:(NSInteger)identifier NS_SWIFT_NAME(performItem(identifier:));

/// Ends the menu without a choice (or after one). Idempotent.
- (void)close;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface OACTab (OACContextMenu)

/// Asks the page for its keyboard context menu (as the context-menu key does): it is for the
/// page's focused element or selection (the page itself when neither), placed at `point` (points,
/// the page's view, origin top left). The page's `contextmenu` handlers run first, then
/// `-tab:showContextMenu:` follows if the page did not cancel it. The page gets keyboard focus
/// first. For a keyboard menu command and tests.
- (void)requestContextMenuAtPoint:(CGPoint)point NS_SWIFT_NAME(requestContextMenu(at:));

@end

/// The `chrome.contextMenus` items an extension added for its toolbar action
/// (`contexts: ["action"]`, also "all"), for the shell's action menu (plan B116, B124).
@interface OACProfile (OACExtensionActionMenu)

/// The action items of `extensionIdentifier`, in the extension's order (submenus included), for a
/// right-click on its action while `tab` shows. Empty for an unknown or disabled extension, or one
/// without such items.
- (NSArray<OACContextMenuItem *> *)actionMenuItemsForExtension:(NSString *)extensionIdentifier
                                                           tab:(nullable OACTab *)tab
    NS_SWIFT_NAME(actionMenuItems(extensionIdentifier:tab:));

/// Runs one of those items (the extension's `contextMenus.onClicked` fires, with `tab`). Ignored
/// when the item is gone.
- (void)performActionMenuItemWithIdentifier:(NSInteger)identifier
                                  extension:(NSString *)extensionIdentifier
                                        tab:(nullable OACTab *)tab
    NS_SWIFT_NAME(performActionMenuItem(identifier:extensionIdentifier:tab:));

@end

NS_ASSUME_NONNULL_END
