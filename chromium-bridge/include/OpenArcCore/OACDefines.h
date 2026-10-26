// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OpenArcCore: shared macros, error domain and small value types of the Chromium bridge.
//
// Every public header of OpenArcCore.framework imports this file. The framework is built with
// Chromium's `-fvisibility=hidden`, so every public class carries `OAC_EXPORT` and every public C
// symbol carries `OAC_EXTERN`; nothing of Chromium itself is exported (chromium-bridge/README.md
// §Build and packaging).
//
// Threading contract for the whole framework (README §Threading): every class and protocol that is
// not an immutable value is main-thread only (`NS_SWIFT_UI_ACTOR`, imported into Swift as
// `@MainActor`). Chromium's BrowserThread::UI is the macOS main thread. The bridge calls delegates
// and completion handlers on the main thread, from a posted task, never re-entrantly from inside a
// call the shell made and never from inside a Chromium observer iteration.
//
// Immutable value objects (state snapshots, request descriptions) are `NS_SWIFT_SENDABLE`.
//
// No header except OACBrowserApplication.h imports AppKit. Views are passed as a forward-declared
// `NSView`, which Swift imports as an opaque class (SE-0384), so the Swift target that wraps this
// framework (`OpenArcChromium`, plan C8) can hand the view to `SurfaceContent.native(AnyObject)`
// without importing AppKit itself. Images cross the bridge as PNG bytes, like `Favicon.pngData`
// and `EngineSnapshot.pngData` in app/Sources/OpenArcEngine/BrowserEngine.swift.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#if defined(__cplusplus)
#define OAC_EXTERN extern "C" __attribute__((visibility("default")))
#else
#define OAC_EXTERN extern __attribute__((visibility("default")))
#endif

/// Marks a public Objective-C class as exported from OpenArcCore.framework.
#define OAC_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

/// Version of this header set. Bumped on every incompatible change; `OpenArcChromium` checks it
/// against the value it was compiled with at startup.
OAC_EXTERN const NSInteger OACBridgeAPIVersion;

/// Error domain of every NSError the bridge returns. Swift imports the codes as `OACError`.
OAC_EXTERN NSErrorDomain const OACErrorDomain;

/// Error codes. Where `EngineError` (BrowserEngine.swift) has a matching case it is named per
/// case; the others are proposed additions (SWIFT_PROTOCOL_CHANGES.md §13).
typedef NS_ERROR_ENUM(OACErrorDomain, OACErrorCode) {
    /// `OACApplication` is not running (never started, or already shut down).
    OACErrorNotStarted = 1,
    /// `-startWithConfiguration:error:` was called twice.
    OACErrorAlreadyStarted = 2,
    /// The profile could not be created or loaded, or it was destroyed.
    OACErrorProfileUnavailable = 3,
    /// The tab is closed. `EngineError.tabClosed`.
    OACErrorTabClosed = 4,
    /// A live tab already has the requested identifier. `EngineError.duplicateTabID`.
    OACErrorDuplicateTabIdentifier = 5,
    /// No frame to copy (hidden, crashed or not painted yet). `EngineError.snapshotUnavailable`.
    OACErrorSnapshotUnavailable = 6,
    /// The URL is invalid or uses a scheme the engine refuses to navigate to.
    OACErrorInvalidURL = 7,
    /// The engine is shutting down and refuses new work.
    OACErrorShuttingDown = 8,
    /// A parameter is out of range (for example a zoom level).
    OACErrorInvalidArgument = 9,
    /// The request was already answered, or it was cancelled by the engine.
    OACErrorRequestFinished = 10,
};

/// Main-frame security level of the visible navigation entry, derived from Chromium's security
/// state. Drives the "Secure" pill of the Site Control Center ([06 §12] observed label; today the
/// shell derives it from the URL scheme alone, see `SiteOrigin.isSecure`).
typedef NS_ENUM(NSInteger, OACSecurityLevel) {
    /// http, file, about: and other pages without a secure connection.
    OACSecurityLevelNone = 0,
    /// A valid HTTPS connection.
    OACSecurityLevelSecure = 1,
    /// HTTPS with mixed or otherwise degraded content.
    OACSecurityLevelWarning = 2,
    /// A certificate error the user clicked through, or a site flagged as dangerous.
    OACSecurityLevelDangerous = 3,
};

/// An sRGB color with straight alpha, components 0...1. Mirrors `RGBAColor` in OpenArcModel.
typedef struct OACColor {
    double red;
    double green;
    double blue;
    double alpha;
} OACColor;

/// A site's origin: scheme, host and port. Mirrors `SiteOrigin` in
/// app/Sources/OpenArcShell/SiteControls/SiteSettingsProvider.swift (scheme and host lowercased;
/// port nil when it is the scheme's default).
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACOrigin : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *scheme;
@property (nonatomic, readonly, copy) NSString *host;
/// nil: the scheme's default port.
@property (nonatomic, readonly, copy, nullable) NSNumber *port;

- (instancetype)initWithScheme:(NSString *)scheme host:(NSString *)host port:(nullable NSNumber *)port NS_DESIGNATED_INITIALIZER;
/// nil for URLs without a host (about:blank, file URLs, data URLs).
- (nullable instancetype)initWithURL:(NSURL *)url;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
