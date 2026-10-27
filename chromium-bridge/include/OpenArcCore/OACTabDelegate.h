// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACTabDelegate: navigation, loading and page events of one tab.
//
// Maps to: `TabEvent` (one callback per case) and the tab-originated `EngineEvent`s
// (`newTabRequested`, `tabClosed`) in app/Sources/OpenArcEngine/BrowserEngine.swift. Plan task C9.
// The Chromium side is a `content::WebContentsObserver` (URL, title, load, navigation, audio,
// crash) plus a `content::WebContentsDelegate` (new tabs, close requests, fullscreen) plus the
// favicon driver observer, all owned by the `OACTab`.
//
// Delivery rules (README §Threading):
// - On the main thread, from a posted task, in the order Chromium produced the changes.
// - Coalesced per run loop turn where Chromium may fire many times (load progress, title).
// - A callback carries the new value and the tab's `state` already reflects it.
// - After `tabDidClose:` nothing else is delivered for that tab.
//
// Swift wrapper mapping (`OpenArcChromium`, plan C8/C9):
//   tab:didChangeURL:                     -> TabEvent.urlChanged
//   tab:didChangeTitle:                   -> TabEvent.titleChanged
//   tab:didChangeLoading:progress:        -> TabEvent.loadStateChanged
//   tab:didChangeFaviconURL:pngData:      -> TabEvent.faviconChanged
//   tab:didChangeCanGoBack:canGoForward:  -> TabEvent.navigationStateChanged
//   tab:didChangeAudioState:              -> TabEvent.audioStateChanged
//   tab:renderProcessDidTerminate:        -> TabEvent.renderProcessGone
//   tabDidClose:                          -> TabEvent.closed + EngineEvent.tabClosed
//   tab:didRequestNewTab:                 -> EngineEvent.newTabRequested
//   everything else                       -> proposed events, SWIFT_PROTOCOL_CHANGES.md

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

/// How the page asked for a new tab. Maps to `NewTabDisposition`; Chromium's
/// `WindowOpenDisposition` is folded into these four (current-tab navigations never reach the
/// delegate, they just navigate).
typedef NS_ENUM(NSInteger, OACNewTabDisposition) {
    /// `NewTabDisposition.foregroundTab` (target=_blank, ⌘⇧-click).
    OACNewTabDispositionForegroundTab = 0,
    /// `NewTabDisposition.backgroundTab` (⌘-click, middle click).
    OACNewTabDispositionBackgroundTab = 1,
    /// `NewTabDisposition.newWindow` (⇧-click, [06 §4] observed: a new window opened).
    OACNewTabDispositionNewWindow = 2,
    /// `NewTabDisposition.popup` (window.open with window features).
    OACNewTabDispositionPopup = 3,
};

/// A request for a new tab. Maps to `NewTabRequest`.
///
/// Two flavors:
/// - URL requests (link clicks with a disposition, `viewSource`, extension and app requests):
///   `hasPendingContents` is NO. The shell creates a normal tab with `OACTab +tabWithConfiguration:`
///   (with `opener` set) wherever it decides (`TreeOps.openTab` into Today, Little Arc, Peek).
/// - Script-opened windows (`window.open`, target=_blank with opener): Chromium has already made
///   the new WebContents, because the page holds a live `window` reference to it.
///   `hasPendingContents` is YES and the shell must call `-adoptWithIdentifier:error:` (to keep
///   it) or `-decline` within the same main-thread turn or soon after; an unanswered request is
///   declined when the opener closes. This is the gap noted in SWIFT_PROTOCOL_CHANGES.md §1:
///   `NewTabRequest` has no way to hand over an engine-created tab today.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACNewTabRequest : NSObject

/// The tab that asked; nil for requests from outside a tab (`OACApplicationDelegate`).
@property (nonatomic, readonly, weak, nullable) OACTab *opener;
/// The profile the new tab must use (the opener's; an incognito opener yields its OTR profile).
@property (nonatomic, readonly) OACProfile *profile;
@property (nonatomic, readonly, copy) NSURL *URL;
@property (nonatomic, readonly) OACNewTabDisposition disposition;
/// `NewTabRequest.hasUserGesture`. Popups without a gesture are already filtered by Chromium's
/// popup blocker before they reach the delegate (blocked ones are reported through
/// `-tab:didBlockPopupWithURL:`).
@property (nonatomic, readonly) BOOL hasUserGesture;
/// Requested popup frame in screen points from `window.open` features; `CGRectNull` if none.
@property (nonatomic, readonly) CGRect requestedFrame;

/// See the class comment.
@property (nonatomic, readonly) BOOL hasPendingContents;

/// Keeps the engine-created contents as a new live tab with this identifier. Only valid when
/// `hasPendingContents` is YES and the request was not answered yet; else returns nil with
/// `OACErrorRequestFinished`.
- (nullable OACTab *)adoptWithIdentifier:(nullable NSUUID *)identifier error:(NSError **)error NS_SWIFT_NAME(adopt(identifier:));
/// Discards the request (and the pending contents, if any). Idempotent.
- (void)decline;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Why a renderer process ended. Maps to `TabEvent.renderProcessGone` (which carries no reason;
/// see SWIFT_PROTOCOL_CHANGES.md §7).
typedef NS_ENUM(NSInteger, OACRenderProcessTermination) {
    OACRenderProcessTerminationCrashed = 0,
    OACRenderProcessTerminationKilled = 1,
    OACRenderProcessTerminationOutOfMemory = 2,
    OACRenderProcessTerminationLaunchFailed = 3,
};

/// A main-frame navigation that finished (committed or failed). For history and future engine
/// tests; the shell only needs URL/title/load today.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACNavigation : NSObject
@property (nonatomic, readonly, copy) NSURL *URL;
/// NO for same-document navigations (fragment, pushState).
@property (nonatomic, readonly) BOOL isCrossDocument;
/// Started by the page (link, script) rather than by the shell.
@property (nonatomic, readonly) BOOL isRendererInitiated;
/// nil when it committed; the net error otherwise (Chromium shows its own error page).
@property (nonatomic, readonly, copy, nullable) NSError *error;
/// HTTP status of the main resource; 0 when there was none.
@property (nonatomic, readonly) NSInteger HTTPStatusCode;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Tab events, on the main thread. All optional.
NS_SWIFT_UI_ACTOR
@protocol OACTabDelegate <NSObject>
@optional

// MARK: State changes (C9; one `TabEvent` each)

- (void)tab:(OACTab *)tab didChangeURL:(nullable NSURL *)url NS_SWIFT_NAME(tab(_:didChangeURL:));
- (void)tab:(OACTab *)tab didChangeTitle:(NSString *)title;
- (void)tab:(OACTab *)tab didChangeLoading:(BOOL)isLoading progress:(double)progress;
- (void)tab:(OACTab *)tab didChangeFaviconURL:(nullable NSURL *)faviconURL pngData:(nullable NSData *)pngData;
- (void)tab:(OACTab *)tab didChangeCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)tab:(OACTab *)tab didChangeAudioState:(OACAudioState)audioState;
- (void)tab:(OACTab *)tab renderProcessDidTerminate:(OACRenderProcessTermination)reason;

/// The tab is closed (by `-close`, by the shell accepting a close request, or by engine shutdown).
- (void)tabDidClose:(OACTab *)tab;

// MARK: State changes without a `TabEvent` yet (SWIFT_PROTOCOL_CHANGES.md §6)

- (void)tab:(OACTab *)tab didChangeSecurityLevel:(OACSecurityLevel)securityLevel;
- (void)tab:(OACTab *)tab didChangeZoomFactor:(double)zoomFactor;
- (void)tab:(OACTab *)tab didChangeCaptureState:(OACCaptureState)captureState;
/// `<meta name="theme-color">` appeared, changed or went away (plan C17).
- (void)tab:(OACTab *)tab didChangeThemeColor:(OACColor)color hasThemeColor:(BOOL)hasThemeColor;
/// A finished load was sampled: `tab.state.pageTopColorKind` / `pageTopColor` changed (plan B45).
- (void)tabDidSamplePageTopColor:(OACTab *)tab;
/// The page entered or left HTML fullscreen. The shell hides the sidebar and makes the window full
/// screen (inferred; the spec records no page-fullscreen behavior).
- (void)tab:(OACTab *)tab didChangeFullscreen:(BOOL)isFullscreen;
- (void)tab:(OACTab *)tab didFinishNavigation:(OACNavigation *)navigation;
/// `tab.translationState` changed (plan B47, OACTranslation.h).
- (void)tabDidChangeTranslationState:(OACTab *)tab;

// MARK: Requests (C9)

/// The page (or Chromium, for `viewSource`) wants a new tab. See `OACNewTabRequest`.
/// Maps to `EngineEvent.newTabRequested`.
- (void)tab:(OACTab *)tab didRequestNewTab:(OACNewTabRequest *)request;

/// A popup was blocked; the shell may offer to open it. inferred: no spec surface.
- (void)tab:(OACTab *)tab didBlockPopupWithURL:(NSURL *)url;

/// The page asked to close itself (`window.close()` on a script-opened tab, or the user's
/// `-closeRunningUnloadHandlers` passed beforeunload). The tab stays open until the shell calls
/// `-close`: the shell archives or removes the model tab through `TreeOps` first. Proposed event
/// `TabEvent.closeRequested` (SWIFT_PROTOCOL_CHANGES.md §2).
- (void)tabDidRequestClose:(OACTab *)tab;

/// The page wants focus (window.focus()); the shell may select the tab. inferred.
- (void)tabDidRequestActivation:(OACTab *)tab;

/// Hovered link changed (status bubble at the bottom of the web panel, inferred; nil when the
/// pointer leaves the link).
- (void)tab:(OACTab *)tab didHoverLinkURL:(nullable NSURL *)url;

/// A keyboard event the page did not consume. The shell returns YES when it handled it (so the
/// app's shortcuts such as ⌘T, ⌘L, ⌘S keep working while the page has focus). The event is the
/// `NSEvent`, typed `id` so this header stays free of AppKit.
- (BOOL)tab:(OACTab *)tab handleUnhandledKeyEvent:(id)event;

/// A context menu is about to show. The bridge draws Chromium's own menu items in an `NSMenu`;
/// the shell may add items (Open Link in Split View, Open in Little Arc). inferred: the web page
/// context menu is not in the spec. `menu` is the `NSMenu`, typed `id` for the same reason.
- (void)tab:(OACTab *)tab willShowContextMenu:(id)menu forLinkURL:(nullable NSURL *)linkURL;

// MARK: Find in page (C12)

/// Results of `-findString:options:`. `isFinal` is YES once the whole page was searched.
- (void)tab:(OACTab *)tab
    didUpdateFindResultForRequest:(NSInteger)requestIdentifier
                     numberOfMatches:(NSInteger)numberOfMatches
                  activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                             isFinal:(BOOL)isFinal;

@end

NS_ASSUME_NONNULL_END
