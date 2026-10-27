// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACLinkPreview: link clicks the shell previews instead of letting the tab navigate (plan B49,
// Peek, docs/arc-spec/06-flows.md §22).
//
// Maps to: `BrowserTab.setLinkPreviewTriggers(_:)` and `TabEvent.linkPreviewRequested` in
// app/Sources/OpenArcEngine/BrowserEngine.swift.
//
// The shell tells each tab which clicks to intercept: favorites and pinned tabs intercept plain
// clicks on links to other sites ([06 §22.1] observed), every tab Shift-clicks ([06 §22.1]
// observed in a Today tab). The bridge decides before the navigation starts, drops the click
// (the tab stays on its page, with no history entry and no error page) and reports it to the tab
// delegate, if it implements `OACLinkPreviewDelegate`. A tab with no triggers behaves as before
// (Shift-click asks for a new window through `tab:didRequestNewTab:`).
//
// What counts:
// - Other site: a user click on an http(s) link in the main frame that would navigate the tab
//   itself, whose registrable domain differs from the page's. Scripted navigations, form posts,
//   redirects and links in subframes navigate as usual (inferred).
// - Shift-click: a user Shift-click on an http(s) link anywhere in the page (Chromium's
//   new-window disposition). ⌘-click and ⌘⇧-click keep opening tabs.

#import <OpenArcCore/OACTab.h>
#import <OpenArcCore/OACTabDelegate.h>

NS_ASSUME_NONNULL_BEGIN

/// Which link clicks a tab intercepts. Maps to `LinkPreviewTriggers`.
typedef NS_OPTIONS(NSUInteger, OACLinkPreviewTriggers) {
    OACLinkPreviewTriggersNone = 0,
    /// A plain click on a link to another site.
    OACLinkPreviewTriggersOtherSiteLink = 1 << 0,
    /// A Shift-click on a link.
    OACLinkPreviewTriggersShiftClick = 1 << 1,
};

@interface OACTab (OACLinkPreview)

/// The clicks this tab intercepts; none by default. Takes effect for the next click.
@property (nonatomic) OACLinkPreviewTriggers linkPreviewTriggers;

@end

/// Implemented by a tab delegate that wants intercepted clicks. On the main thread, from a posted
/// task, like every `OACTabDelegate` callback.
NS_SWIFT_UI_ACTOR
@protocol OACLinkPreviewDelegate <OACTabDelegate>

/// The tab dropped a click on a link to `url`. `trigger` is the single trigger that matched.
- (void)tab:(OACTab *)tab didInterceptLinkToURL:(NSURL *)url trigger:(OACLinkPreviewTriggers)trigger
    NS_SWIFT_NAME(tab(_:didInterceptLinkTo:trigger:));

@end

NS_ASSUME_NONNULL_END
