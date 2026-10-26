// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACSiteSettings: per-site settings of one profile.
//
// Maps to: `SiteSettingsProvider` in app/Sources/OpenArcShell/SiteControls/SiteSettingsProvider.swift
// (the Site Control Center popover, [06 §12] observed rows). Method by method:
//   settings(for:profileID:)              -> -settingsForOrigin:completionHandler:
//   apply(.permission(kind, decision))    -> -setDecision:forPermission:origin:
//   apply(.developerMode)                 -> -setDeveloperModeEnabled:forOrigin:
//   apply(.automaticPictureInPicture)     -> -setAutomaticPictureInPictureAllowed:forOrigin:
//   apply(.zoom(percent:))                -> -setZoomFactor:forOrigin:
//   apply(.adBlocking)                    -> -setAdBlockingEnabled:forOrigin:  (plan C16; read back
//                                            with -isAdBlockingEnabledForOrigin:)
//   apply(.clearSiteData)                 -> -clearDataForOrigin:completionHandler:
//   runExtensionAction(...)               -> -[OACExtensions runActionOfExtension:onTab:] (C14)
// `profileID` in the Swift protocol picks the `OACProfile`, whose `siteSettings` this is.
// An off-the-record profile has its own settings, which start from its original's (Chromium's
// incognito inheritance rules, e.g. "block" is inherited, "allow" is not for most permissions).
//
// The Chromium side: `HostContentSettingsMap` and the permission manager (decisions),
// `HostZoomMap` (zoom), the cookie manager (cookie count), `BrowsingDataRemover` (clear),
// Picture in Picture's auto-enter content setting. "Developer Mode" is not a Chromium concept: it
// is stored as our own per-origin content setting (website setting registered by the bridge) whose
// meaning is decided by the shell. unknown: the spec records the row and its default, not what it
// does.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACDialogDelegate.h>

NS_ASSUME_NONNULL_BEGIN

@class OACProfile;

/// A stored permission decision. Maps to `SitePermissionDecision` (`.ask` = no stored decision).
typedef NS_ENUM(NSInteger, OACPermissionDecision) {
    OACPermissionDecisionAsk = 0,
    OACPermissionDecisionAllow = 1,
    OACPermissionDecisionBlock = 2,
};

/// Everything the Site Control Center shows for one site. Maps to `SiteSettingsState`.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACSiteSettingsState : NSObject <NSCopying>
/// Stored decisions keyed by `OACPermissionKind` (NSNumber); kinds without a decision are absent
/// (`SiteSettingsState.permissions`).
@property (nonatomic, readonly, copy) NSDictionary<NSNumber *, NSNumber *> *permissionDecisions NS_REFINED_FOR_SWIFT;
/// `isDeveloperModeOn`; default NO ([06 §12] observed "Off").
@property (nonatomic, readonly, getter=isDeveloperModeEnabled) BOOL developerModeEnabled;
/// `isAutomaticPictureInPictureAllowed`; default YES ([06 §12] observed "Allowed").
@property (nonatomic, readonly, getter=isAutomaticPictureInPictureAllowed) BOOL automaticPictureInPictureAllowed;
/// Zoom factor for the site; 1.0 = default. `zoomPercent` = round(factor × 100).
@property (nonatomic, readonly) double zoomFactor;
/// Cookies stored for the site and its subdomains (`cookieCount`).
@property (nonatomic, readonly) NSInteger cookieCount;
/// Ad blocking on this site (`isAdBlockingOn`, plan C16): NO when the site is on the allow list,
/// else the global switch (`OACApplication.adBlockingEnabled`). nil when the framework has no
/// filter ruleset.
@property (nonatomic, readonly, copy, nullable) NSNumber *adBlockingEnabled;

- (OACPermissionDecision)decisionForPermission:(OACPermissionKind)kind NS_SWIFT_NAME(decision(for:));
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@class OACSiteSettings;

/// Stored settings changed (another tab's prompt answered, settings page, sync of Chromium
/// prefs). The Site Control Center refreshes if it shows `origin`. nil origin: many sites changed.
NS_SWIFT_UI_ACTOR
@protocol OACSiteSettingsObserver <NSObject>
- (void)siteSettings:(OACSiteSettings *)siteSettings didChangeForOrigin:(nullable OACOrigin *)origin;
@end

OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACSiteSettings : NSObject

/// The owning profile. Weak: the profile owns this object.
@property (nonatomic, readonly, weak, nullable) OACProfile *profile;

/// Reads the state. Async because the cookie count lives in the network service.
- (void)settingsForOrigin:(OACOrigin *)origin
        completionHandler:(void (^)(OACSiteSettingsState *state))completionHandler
    NS_SWIFT_NAME(settings(for:completionHandler:));

- (void)setDecision:(OACPermissionDecision)decision forPermission:(OACPermissionKind)kind origin:(OACOrigin *)origin
    NS_SWIFT_NAME(setDecision(_:for:origin:));
- (void)setDeveloperModeEnabled:(BOOL)enabled forOrigin:(OACOrigin *)origin;
- (void)setAutomaticPictureInPictureAllowed:(BOOL)allowed forOrigin:(OACOrigin *)origin;
/// Stores the zoom for the origin's host; open tabs on it follow. 1.0 removes the entry.
- (BOOL)setZoomFactor:(double)zoomFactor forOrigin:(OACOrigin *)origin error:(NSError **)error;
/// Plan C16. NO puts the origin's site on the ad blocker's allow list (Chromium's "ads" content
/// setting, per profile; off-the-record profiles inherit it); YES removes it again. Open tabs on
/// the site follow at their next page load.
- (void)setAdBlockingEnabled:(BOOL)enabled forOrigin:(OACOrigin *)origin;
/// Plan C16. NO when the origin is on the allow list; the global switch does not affect it.
- (BOOL)isAdBlockingEnabledForOrigin:(OACOrigin *)origin NS_SWIFT_NAME(isAdBlockingEnabled(forOrigin:));
/// Removes cookies, storage, cache and stored permissions of the origin's site (eTLD+1).
- (void)clearDataForOrigin:(OACOrigin *)origin completionHandler:(void (^)(void))completionHandler;

/// Origins with any stored setting, for a future "all sites" list. inferred.
- (void)originsWithStoredSettingsWithCompletionHandler:(void (^)(NSArray<OACOrigin *> *origins))completionHandler;

/// Observers are held weakly.
- (void)addObserver:(id<OACSiteSettingsObserver>)observer;
- (void)removeObserver:(id<OACSiteSettingsObserver>)observer;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
