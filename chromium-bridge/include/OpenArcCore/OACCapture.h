// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACCapture: page capture for the shell's capture tools (plan B51, docs/arc-spec/06-flows.md §24).
//
// Maps to: `BrowserTab.capture(_:)` with `PageCaptureArea` (app/Sources/OpenArcEngine/
// BrowserEngine.swift). Images cross the bridge as PNG bytes at the screen's pixel density, like
// `-[OACTab snapshotWithMaxPixelSize:completionHandler:]`.
//
// - Visible capture copies the last painted frame of the tab's view (the region capture of §24.1).
// - Full-page capture renders the document beyond the viewport through the DevTools protocol's
//   `Page.captureScreenshot` with `captureBeyondViewport` (§24.2, and the portrait mode of §24.3 with
//   a height limit). The bridge attaches its own protocol client to the tab for the duration of the
//   capture and detaches afterwards; the page is laid out at its full height for a moment, as in
//   Chrome's DevTools "Capture full size screenshot".

#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

/// Completion handlers get PNG data and its size in pixels, or an error, on the main thread.
@interface OACTab (OACCapture)

/// Copies `rect` of the visible page (points in `nativeView` coordinates, origin top left) at the
/// screen's pixel density; `CGRectNull` copies the whole visible page. The rectangle is clipped to
/// the view. Fails with `OACErrorSnapshotUnavailable` (no frame: hidden without a cached frame,
/// crashed, closed) or `OACErrorInvalidArgument` (nothing of `rect` lies inside the view).
- (void)captureVisibleRect:(CGRect)rect
         completionHandler:(void (^)(NSData *_Nullable pngData, CGSize pixelSize, NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(captureVisible(rect:completionHandler:));

/// Renders the whole document from its top, beyond the viewport, at the screen's pixel density
/// (scaled down when a side would exceed 16384 pixels). `maximumAspectRatio` (height / width) > 0
/// keeps only the top part of the page up to that ratio; 0 keeps the whole page. Fails with
/// `OACErrorSnapshotUnavailable` when the page cannot be rendered (closed, crashed, still without a
/// document, or the renderer gave up within 20 s).
- (void)captureFullPageWithMaximumAspectRatio:(double)maximumAspectRatio
                            completionHandler:(void (^)(NSData *_Nullable pngData, CGSize pixelSize, NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(captureFullPage(maximumAspectRatio:completionHandler:));

@end

NS_ASSUME_NONNULL_END
