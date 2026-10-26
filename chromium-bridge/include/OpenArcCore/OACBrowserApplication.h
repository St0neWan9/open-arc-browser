// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACBrowserApplication: the NSApplication subclass Chromium needs in the browser process.
//
// Chromium's Mac event handling (nested run loops for menus and drags, `sendEvent:` tracking that
// keeps tasks from running inside an event dispatch, the shutdown path) relies on the
// NSApplication being a class that tracks "is handling sendEvent". `content_shell` and Chrome
// use their own subclasses for this; ours is `OACBrowserApplication`, which the bridge implements
// against Chromium's protocols in the .mm file (they are not part of this public header so the
// shell never sees a Chromium type).
//
// Wiring (plan C8, the shell side): the bundle's Info.plist sets
// `NSPrincipalClass = OACBrowserApplication`. SwiftUI's `App` uses `NSApplication.shared`, which
// instantiates the principal class, so the SwiftUI scene, menus and `OpenArcAppDelegate`
// (`NSApplicationDelegateAdaptor`) keep working unchanged. Before `OACApplication` starts, nothing
// Chromium-specific happens in this class.
//
// This is the only public header that imports AppKit.

#import <AppKit/AppKit.h>
#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACBrowserApplication : NSApplication

/// YES while `-sendEvent:` is on the stack. Chromium reads it to decide whether a task may run
/// now or must wait for the event to finish.
@property (nonatomic, readonly, getter=isHandlingSendEvent) BOOL handlingSendEvent;

@end

NS_ASSUME_NONNULL_END
