// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACTab: one live web contents.
//
// Maps to: `BrowserTab` and its `TabSurface` (app/Sources/OpenArcEngine/BrowserEngine.swift,
// Surface.swift); `OACTabConfiguration` maps to `TabConfiguration`; `OACTabState` maps to
// `BrowserTabState`. The Chromium side wraps one `content::WebContents` plus the tab helpers
// `//chrome` attaches to a tab (favicon driver, find, zoom, permissions, password manager,
// autofill, extensions, content settings), created the way Chrome creates a tab but with no
// `Browser` or `TabStripModel` (README §Keeping //chrome without its UI).
// Plan tasks: C8 (create, navigate, host the view), C9 (events), C12 (dialogs), C15 (DevTools,
// view source, print, Picture in Picture), C17 (page top color).
//
// Ownership (README §Ownership): `OACTab` owns its WebContents. The tab is alive from creation
// until `-close` (or an `OACTabDelegate` close request that the shell accepts by calling
// `-close`). After `-close`, `isClosed` is YES, `nativeView` is nil, commands fail with
// `OACErrorTabClosed`, and the delegate gets `tabDidClose:` exactly once. Releasing the last
// reference to an open tab closes it too (the bridge never keeps a tab alive on its own), so the
// Swift wrapper (`OpenArcChromium`) holds a strong reference per live `EngineTabID` and drops it in
// `closeTab`.
//
// Event model: the bridge calls `OACTabDelegate` (OACTabDelegate.h) on the main thread; the Swift
// wrapper turns each call into a `TabEvent` on the tab's `AsyncBroadcaster`, with
// `.snapshot(currentState)` built from `-state` as the first element of every new stream.

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class NSView;
@class OACProfile;
@class OACTab;
@class OACTabState;
@class OACFindOptions;
@protocol OACTabDelegate;
@protocol OACDialogDelegate;

// MARK: - Configuration

/// The color scheme a page sees through `prefers-color-scheme`. Maps to `WebColorScheme`
/// (app/Sources/OpenArcEngine/BrowserEngine.swift; B21, [04 §dark mode] observed).
typedef NS_ENUM(NSInteger, OACColorScheme) {
    OACColorSchemeLight = 0,
    OACColorSchemeDark = 1,
};

/// Parameters for creating a tab. Maps to `TabConfiguration`.
OAC_EXPORT
@interface OACTabConfiguration : NSObject <NSCopying>

/// The browsing context. Pass `profile.offTheRecordProfile` for `TabConfiguration.isOffTheRecord`.
@property (nonatomic, strong) OACProfile *profile;

/// Loaded right away. nil: a blank page (about:blank, no history entry).
@property (nonatomic, copy, nullable) NSURL *initialURL;

/// The tab that opened this one (`TabConfiguration.opener`). Gives the new page `window.opener`
/// and the opener's session storage when `request` came from that opener.
@property (nonatomic, weak, nullable) OACTab *opener;

/// Requested identifier (`TabConfiguration.requestedID`, an `EngineTabID`). nil lets the bridge
/// choose. A live duplicate fails with `OACErrorDuplicateTabIdentifier`.
@property (nonatomic, copy, nullable) NSUUID *requestedIdentifier;

/// Created hidden: the renderer runs at background priority and paints nothing until the tab is
/// shown (`-setVisible:`). Default YES; tabs created for the selected tab pass NO.
@property (nonatomic) BOOL startsHidden;

/// Initial view size in points, so the first layout matches the web panel. Zero: 800×600.
@property (nonatomic) CGSize initialSize;

/// Color scheme the page sees from its first load (`TabConfiguration.preferredColorScheme`).
/// Default light.
@property (nonatomic) OACColorScheme preferredColorScheme;

- (instancetype)initWithProfile:(OACProfile *)profile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// MARK: - State snapshot

/// Audio state. Maps to `AudioState`.
typedef NS_OPTIONS(NSUInteger, OACAudioState) {
    /// The page is producing sound (regardless of mute).
    OACAudioStateAudible = 1 << 0,
    /// The tab is muted (`-setMuted:`).
    OACAudioStateMuted = 1 << 1,
};

/// Media capture in progress, for the sidebar's recording indicators. Proposed in
/// SWIFT_PROTOCOL_CHANGES.md §6 (no `BrowserTabState` field yet). inferred: the spec records no
/// indicator.
typedef NS_OPTIONS(NSUInteger, OACCaptureState) {
    OACCaptureStateCamera = 1 << 0,
    OACCaptureStateMicrophone = 1 << 1,
    OACCaptureStateScreen = 1 << 2,
};

/// Immutable snapshot of a tab's observable state. Maps to `BrowserTabState`; the fields that
/// `BrowserTabState` lacks are listed in SWIFT_PROTOCOL_CHANGES.md §6.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACTabState : NSObject <NSCopying>

/// Visible URL (`BrowserTabState.url`): the pending URL during a browser-initiated navigation, the
/// committed one otherwise (Chromium's "visible URL" rule, which keeps the address safe from
/// spoofing). nil for a blank tab.
@property (nonatomic, readonly, copy, nullable) NSURL *URL;
/// Last committed URL, for the "Copy URL" family of commands ([01 §Edit] observed items).
@property (nonatomic, readonly, copy, nullable) NSURL *committedURL;
/// Page title; empty when the page has none (`BrowserTabState.title`).
@property (nonatomic, readonly, copy) NSString *title;

/// `LoadState.isLoading`.
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
/// `LoadState.progress`, 0...1.
@property (nonatomic, readonly) double loadProgress;

/// `Favicon.url`.
@property (nonatomic, readonly, copy, nullable) NSURL *faviconURL;
/// `Favicon.pngData`: the decoded icon at the size the bridge picked (32 px), as PNG.
@property (nonatomic, readonly, copy, nullable) NSData *faviconPNGData;

/// `NavigationState`.
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;

/// `BrowserTabState.isCrashed`: the renderer died and the page was not reloaded since.
@property (nonatomic, readonly, getter=isCrashed) BOOL crashed;

/// `BrowserTabState.audio`.
@property (nonatomic, readonly) OACAudioState audioState;

// Fields with no `BrowserTabState` counterpart yet (SWIFT_PROTOCOL_CHANGES.md §6).

/// Security of the visible entry (Site Control Center "Secure" pill).
@property (nonatomic, readonly) OACSecurityLevel securityLevel;
/// Page zoom as a factor (1.0 = 100 %). See `-setZoomFactor:`.
@property (nonatomic, readonly) double zoomFactor;
/// Camera, microphone or screen capture in use.
@property (nonatomic, readonly) OACCaptureState captureState;
/// The page is in HTML fullscreen (element.requestFullscreen).
@property (nonatomic, readonly, getter=isFullscreen) BOOL fullscreen;
/// The page's `<meta name="theme-color">`, if any (plan C17).
@property (nonatomic, readonly) BOOL hasThemeColor;
@property (nonatomic, readonly) OACColor themeColor;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// MARK: - Find in page

/// Options for `-findString:options:`. Edit ▸ Find ▸ Find… / Find Next / Find Previous /
/// Use Selection to Find ([01 §Edit] observed items; the find bar look is not in the spec).
OAC_EXPORT
@interface OACFindOptions : NSObject <NSCopying>
/// Search backwards (Find Previous).
@property (nonatomic) BOOL backwards;
/// Case sensitive. Default NO.
@property (nonatomic) BOOL matchCase;
/// YES: continue from the current match (Find Next / Previous); NO: a new search.
@property (nonatomic) BOOL findNext;
@end

// MARK: - Tab

/// One live web contents.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACTab : NSObject

/// Creates a tab. On success the tab exists right away and starts loading `initialURL`; the
/// delegate (set right after) gets the first callbacks from the next main-thread task, so no event
/// is lost. Fails with `OACErrorProfileUnavailable`, `OACErrorDuplicateTabIdentifier`,
/// `OACErrorInvalidURL` or `OACErrorNotStarted`. Maps to `BrowserEngine.makeTab`.
+ (nullable instancetype)tabWithConfiguration:(OACTabConfiguration *)configuration error:(NSError **)error
    NS_SWIFT_NAME(init(configuration:));

/// The live tab with this identifier, if any. Maps to `BrowserEngine.tab(for:)`.
+ (nullable OACTab *)tabWithIdentifier:(NSUUID *)identifier NS_SWIFT_NAME(tab(identifier:));

/// `EngineTabID.rawValue`.
@property (nonatomic, readonly, copy) NSUUID *identifier;
/// The browsing context (`BrowserTab.profileID` is `profile.identifier`).
@property (nonatomic, readonly) OACProfile *profile;

/// Navigation, loading and page events. Weak.
@property (nonatomic, weak, nullable) id<OACTabDelegate> delegate;
/// Shell-drawn dialogs (plan C12). Weak. With no dialog delegate, every request gets its default
/// answer (alerts dismissed, permissions denied, auth cancelled) so a page never hangs.
@property (nonatomic, weak, nullable) id<OACDialogDelegate> dialogDelegate;

/// Current state (`BrowserTab.currentState`). A new snapshot object after every change.
@property (nonatomic, readonly, copy) OACTabState *state;

@property (nonatomic, readonly, getter=isClosed) BOOL closed;

// MARK: Navigation (`BrowserTab.load / goBack / goForward / reload / stopLoading`)

/// Loads a URL as if typed (page transition "typed"). Returns NO with `OACErrorInvalidURL` for an
/// invalid URL or a refused scheme (javascript:), `OACErrorTabClosed` after `-close`.
- (BOOL)loadURL:(NSURL *)url error:(NSError **)error;
/// No-op returning YES when there is nothing to go back to (the shell disables the button from
/// `canGoBack`).
- (BOOL)goBackWithError:(NSError **)error;
- (BOOL)goForwardWithError:(NSError **)error;
/// Reload. `bypassingCache`: View ▸ Force Refresh the Page ([01 §View] observed item).
- (BOOL)reloadBypassingCache:(BOOL)bypassingCache error:(NSError **)error NS_SWIFT_NAME(reload(bypassingCache:));
- (BOOL)stopLoadingWithError:(NSError **)error;

// MARK: Audio (`BrowserTab.setMuted`)

- (void)setMuted:(BOOL)muted;

// MARK: Appearance (`BrowserTab.setPreferredColorScheme`)

/// The color scheme the page sees (`prefers-color-scheme`, and the default colors of pages without
/// their own). Setting it updates the page live; setting the current value does nothing.
@property (nonatomic) OACColorScheme preferredColorScheme;

// MARK: View hosting (`TabSurface`)

/// The view that shows the page. The shell's `SurfaceHost` adds it as a subview and sizes it;
/// the bridge never moves it between superviews itself. A view is in at most one superview at a
/// time, which matches "a surface is in at most one host" in Surface.swift. nil after `-close`.
@property (nonatomic, readonly, nullable) NSView *nativeView;

/// Visibility, which drives renderer priority, painting and `document.visibilityState`.
/// `SurfaceHost` attach makes the tab visible, detach makes it hidden. Occlusion by other windows
/// is detected by Chromium itself.
- (void)setVisible:(BOOL)visible;

/// Keyboard focus into the page (`TabSurface.setFocused`): makes the view first responder of its
/// window and focuses the page's focused element.
- (void)setFocused:(BOOL)focused;

// MARK: Snapshot (`BrowserTab.snapshot`)

/// Copies the last painted frame, scaled so the longer side is at most `maxPixelSize`, as PNG.
/// Fails with `OACErrorSnapshotUnavailable` for a hidden tab without a cached frame or a crashed
/// renderer. The handler runs on the main thread.
- (void)snapshotWithMaxPixelSize:(NSInteger)maxPixelSize
               completionHandler:(void (^)(NSData *_Nullable pngData, CGSize pixelSize, NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(snapshot(maxPixelSize:completionHandler:));

// MARK: Zoom (View ▸ Zoom to Actual Size / Zoom In / Zoom Out, [01 §View] observed items)

/// Sets the page zoom; Chromium stores it per host in the profile's zoom map, so other tabs on
/// the same site follow (the Site Control Center reads it as `SiteSettingsState.zoomPercent`).
/// Valid range 0.25...5.0; others fail with `OACErrorInvalidArgument`.
- (BOOL)setZoomFactor:(double)zoomFactor error:(NSError **)error;
/// Next preset level up (Chromium's preset list), down, or back to the default.
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;

// MARK: Find in page (plan C12; results via `-[OACTabDelegate tab:didUpdateFindResult:...]`)

/// Starts or continues a search. Returns a request id that the matching results carry; an empty
/// string stops the search like `-stopFinding...`.
- (NSInteger)findString:(NSString *)string options:(OACFindOptions *)options NS_SWIFT_NAME(find(_:options:));
/// Ends find-in-page. `keepSelection` leaves the active match selected (Jump to Selection).
- (void)stopFindingKeepingSelection:(BOOL)keepSelection NS_SWIFT_NAME(stopFinding(keepingSelection:));
/// The current selection, for Edit ▸ Find ▸ Use Selection to Find. Async (lives in the renderer).
- (void)selectedTextWithCompletionHandler:(void (^)(NSString *text))completionHandler;

// MARK: Editing and page commands

/// Edit menu commands on the focused frame (Undo, Redo, Cut, Copy, Paste, Paste and Match Style,
/// Delete, Select All; [01 §Edit] observed items). The responder chain reaches the web view
/// already; these exist for the command bar, which is not in the responder chain.
- (void)performEditCommand:(NSString *)command NS_SWIFT_NAME(performEditCommand(_:));

/// File ▸ Print ([01 §File] observed item, plan C15): the macOS print panel for the page (or for
/// the focused frame when it has a selection). Chromium's print preview needs a Browser window's
/// tab-modal host, so the bridge runs with print preview off; `window.print()` shows the same
/// panel. The panel is app-modal (Chromium's Mac printing runs it modally). Swift: `printPage()`,
/// so it does not read as Swift's global `print`.
- (void)print NS_SWIFT_NAME(printPage());

/// Save Page As formats ([01 §File] observed item; the formats are Chromium's, inferred).
typedef NS_ENUM(NSInteger, OACSavePageFormat) {
    /// The HTML file plus a `<name>_files` folder with images, styles and scripts.
    OACSavePageFormatComplete = 0,
    /// The HTML file only.
    OACSavePageFormatHTMLOnly = 1,
    /// One MHTML file (`.mhtml`).
    OACSavePageFormatSingleFile = 2,
};

/// File ▸ Save Page As ([01 §File] observed item): saves the page at `url` (a file URL) as a
/// complete page. Same as `-savePageToURL:format:completionHandler:` with
/// `OACSavePageFormatComplete`.
- (void)savePageToURL:(NSURL *)url completionHandler:(void (^)(NSError *_Nullable error))completionHandler;

/// Saves the page at `url` (a file URL) in `format`. A page that is not HTML (a PDF, an image,
/// media) is saved as its original file whatever the format, as Chromium does. The save runs as a
/// download of the tab's profile (it appears in `OACDownloads`); the handler runs once the save
/// started (nil) or could not start (an error), not when the file is complete.
- (void)savePageToURL:(NSURL *)url
               format:(OACSavePageFormat)format
    completionHandler:(void (^)(NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(savePage(to:format:completionHandler:));

/// View ▸ Developer ▸ Developer Tools / Inspect Elements / JavaScript Console / Network Inspector
/// ([01 §View] observed items, plan C15). DevTools opens in its own window owned by the bridge,
/// one per tab, reused by later calls and closed with the tab (inferred: the spec records no
/// docked DevTools). `panel`: nil = the last panel used, `"elements"` = Inspect Elements (the
/// Elements panel in element-picking mode), `"console"`, `"network"`.
- (void)showDevToolsWithPanel:(nullable NSString *)panel NS_SWIFT_NAME(showDevTools(panel:));
/// Closes this tab's DevTools window, if open.
- (void)closeDevTools;
/// View ▸ Developer ▸ View Source: asks the delegate for a new tab with `view-source:` +URL.
- (void)viewSource;

/// Leaves HTML fullscreen (Escape is handled by the page view itself).
- (void)exitFullscreen;

// MARK: Picture in Picture (plan C15)

// A video's own Picture in Picture button (or `requestPictureInPicture()`) opens Chromium's
// floating Picture in Picture window, which the bridge shows like Chrome does; its "back to tab"
// button reaches the delegate as `tabDidRequestActivation:`. Document Picture in Picture needs a
// Chrome window type the embedder does not have and is refused.

/// A video of this tab is in Picture in Picture.
@property (nonatomic, readonly) BOOL hasPictureInPictureVideo;
/// Puts the tab's video in Picture in Picture. `automatic`: the user left the tab ([03 §Advanced]
/// observed "Enable Picture in Picture when you leave a video tab"): only a playing video that is
/// not in Picture in Picture yet, and only where the site's "Automatic Picture-In-Picture" setting
/// allows it ([06 §12] observed, default Allowed). Not automatic: the tab's single media player,
/// playing or not. Returns whether the request went to the page (the window opens a moment later;
/// `hasPictureInPictureVideo` tells when it is up).
- (BOOL)enterPictureInPictureAutomatically:(BOOL)automatic NS_SWIFT_NAME(enterPictureInPicture(automatically:));
/// Closes the Picture in Picture window if it shows this tab's video.
- (void)exitPictureInPicture;

// MARK: Ad blocking (plan C16)

/// Subresources and frames the built-in ad blocker kept from loading on the current page (all
/// frames); 0 after each new page. Read on demand, no change callback.
@property (nonatomic, readonly) NSInteger blockedAdCount;

// MARK: Lifetime (`BrowserEngine.closeTab`)

/// Closes the tab immediately, without beforeunload handlers. Idempotent.
- (void)close;

/// Runs the page's beforeunload handler first; the delegate's `tabDidRequestClose:` then fires if
/// the page agreed (or the user confirmed the leave-page dialog). For the user's ⌘W.
- (void)closeRunningUnloadHandlers;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
