// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACApplication: the embedded Chromium browser process.
//
// Maps to: the lifetime of the `BrowserEngine` instance (app/Sources/OpenArcEngine/
// BrowserEngine.swift). `OpenArcChromium` (plan C8) starts it once at launch, before the first
// `makeTab`, and shuts it down from the termination flush (`LaunchFlow`'s termination observer).
// Plan tasks: C6 (embedder start), C8 (framework), C11 (profiles), D8 (local crash reports).
//
// Startup model (README §Process model): the app's own NSApplication runs the main run loop. The
// app's principal class is `OACBrowserApplication` (OACBrowserApplication.h) so Chromium's event
// handling contract holds. `-startWithConfiguration:error:` runs Chromium's browser-process
// startup on the main thread and returns once the UI thread is ready to create profiles and tabs;
// it does NOT run a message loop of its own (the bridge's main delegate takes over the browser
// process run step and leaves the loop to AppKit).

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class OACProfile;
@class OACNewTabRequest;
@protocol OACApplicationDelegate;

/// Startup parameters. Copied by `-startWithConfiguration:error:`; later changes have no effect.
OAC_EXPORT
@interface OACApplicationConfiguration : NSObject <NSCopying>

/// Chromium's user data directory. Default profiles live in `<userDataDirectory>/Profiles/<UUID>`.
/// The shell passes `<app data dir>/Chromium`, where the app data dir is
/// `~/Library/Application Support/org.openarc.browser/` or `OPENARC_DATA_DIR` (app/README.md
/// §Data directory), so a development data dir also isolates engine data.
@property (nonatomic, copy) NSURL *userDataDirectory;

/// Disk cache root. nil: `~/Library/Caches/org.openarc.browser/Chromium`.
@property (nonatomic, copy, nullable) NSURL *cacheDirectory;

/// Crashpad database for local crash reports (plan D8, decision Q8: stored locally, never
/// uploaded). nil: `<userDataDirectory>/Crashpad`.
@property (nonatomic, copy, nullable) NSURL *crashDumpDirectory;

/// UI locale for Chromium's own strings (error pages, WebUI), e.g. "en-US". nil: the system's.
@property (nonatomic, copy, nullable) NSString *locale;

/// Process arguments handed to Chromium's command line (`ProcessInfo.arguments`). Unknown
/// switches are ignored by Chromium.
@property (nonatomic, copy) NSArray<NSString *> *arguments;

/// Extra Chromium switches for development (e.g. "--enable-logging=stderr"). Empty in release.
@property (nonatomic, copy) NSArray<NSString *> *additionalSwitches;

/// DevTools remote debugging port; 0 (default) keeps it off.
@property (nonatomic) NSInteger remoteDebuggingPort;

- (instancetype)initWithUserDataDirectory:(NSURL *)userDataDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Lifecycle of the engine.
typedef NS_ENUM(NSInteger, OACApplicationState) {
    OACApplicationStateNotStarted = 0,
    OACApplicationStateRunning = 1,
    OACApplicationStateShuttingDown = 2,
    /// Shut down. Chromium cannot be started twice in one process; relaunch the app instead.
    OACApplicationStateTerminated = 3,
};

/// The browser process. One per app process.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACApplication : NSObject

/// The single instance.
@property (class, nonatomic, readonly) OACApplication *sharedApplication NS_SWIFT_NAME(shared);

@property (nonatomic, readonly) OACApplicationState state;

/// Engine-wide callbacks. Weak.
@property (nonatomic, weak, nullable) id<OACApplicationDelegate> delegate;

/// Starts the browser process: command line, feature list, Chromium threads, the profile manager
/// and the bridge's browser parts. Call once, on the main thread, from
/// `applicationWillFinishLaunching` or later. Returns NO with `OACErrorAlreadyStarted` when called
/// twice.
- (BOOL)startWithConfiguration:(OACApplicationConfiguration *)configuration error:(NSError **)error
    NS_SWIFT_NAME(start(configuration:));

/// Shuts the engine down: closes every tab without running unload handlers, flushes cookies,
/// prefs and history to disk, destroys profiles and joins Chromium's threads. Calls the handler on
/// the main thread when done. Meant for `applicationShouldTerminate:` returning
/// `NSTerminateLater`; the app must exit afterwards.
- (void)shutdownWithCompletionHandler:(void (^)(void))completionHandler NS_SWIFT_NAME(shutdown(completionHandler:));

/// Chromium version, e.g. "156.0.8078.48". Settings ▸ About shows it next to the app version.
@property (nonatomic, readonly, copy) NSString *chromiumVersion;

/// User agent string sent by default (Chromium's reduced UA; no product token of our own, to keep
/// site compatibility).
@property (nonatomic, readonly, copy) NSString *userAgent;

/// The configuration the engine started with; nil before start.
@property (nonatomic, readonly, copy, nullable) OACApplicationConfiguration *configuration;

// MARK: Profiles (plan C11)

/// Loads (creating on first use) the on-disk profile for a model `Profile.id`. Loading reads disk
/// on Chromium's background threads; the handler runs on the main thread. Several calls for the
/// same id share one load and return the same object.
- (void)loadProfileWithIdentifier:(NSUUID *)identifier
                completionHandler:(void (^)(OACProfile *_Nullable profile, NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(loadProfile(identifier:completionHandler:));

/// The profile for `identifier` if it is already loaded, else nil.
- (nullable OACProfile *)loadedProfileWithIdentifier:(NSUUID *)identifier NS_SWIFT_NAME(loadedProfile(identifier:));

/// Every loaded on-disk profile (not the off-the-record ones).
@property (nonatomic, readonly, copy) NSArray<OACProfile *> *loadedProfiles;

/// Deletes a profile's engine data (cookies, storage, history, cache, extensions). Mirrors the
/// model's profile deletion (`TreeOps` delete profile, refused for the Default profile or while
/// Spaces use it). Every tab of the profile must be closed first, else the handler gets
/// `OACErrorInvalidArgument`.
- (void)deleteProfileWithIdentifier:(NSUUID *)identifier
                  completionHandler:(void (^)(NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(deleteProfile(identifier:completionHandler:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Engine-wide callbacks, on the main thread.
NS_SWIFT_UI_ACTOR
@protocol OACApplicationDelegate <NSObject>
@optional

/// Something outside any tab wants a new tab: an extension (`chrome.tabs.create`), a notification
/// click, a WebUI link. `request.opener` is nil. Maps to `EngineEvent.newTabRequested`.
- (void)application:(OACApplication *)application didRequestNewTab:(OACNewTabRequest *)request;

/// A profile's last off-the-record tab closed and its off-the-record context was destroyed
/// (`TabConfiguration.isOffTheRecord`: "the context is destroyed with its last tab").
- (void)application:(OACApplication *)application didDestroyOffTheRecordProfileOfIdentifier:(NSUUID *)identifier;

/// A helper process (GPU, network, utility) died. Renderer crashes go to the tab instead
/// (`-[OACTabDelegate tab:renderProcessDidTerminate:]`).
- (void)application:(OACApplication *)application helperProcessDidTerminateWithName:(NSString *)processName;

@end

NS_ASSUME_NONNULL_END
