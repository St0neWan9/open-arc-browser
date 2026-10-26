// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACProfile: one isolated browsing context.
//
// Maps to: a model `Profile` (`Profile.id`, OpenArcModel) as used in `TabConfiguration.profileID`,
// and the off-the-record variant for `TabConfiguration.isOffTheRecord` (incognito windows,
// `WorkspaceController.makeIncognito`). Plan task C11: on-disk data directory per Profile,
// isolation of cookies and storage. On the Chromium side it wraps one `Profile` (a
// `content::BrowserContext`) owned by Chromium's `ProfileManager`.
//
// Lifetime (README §Ownership):
// - On-disk profiles stay loaded until `OACApplication` shuts down or the profile is deleted.
// - The off-the-record profile is Chromium's primary OTR profile of its original profile. It is
//   created by `offTheRecordProfile` and destroyed when its last tab closes and the shell holds no
//   reference to it, so every incognito window of one profile shares one context while any of them
//   is open (Chromium's usual incognito semantics).
// - When Chromium destroys the underlying profile, `isValid` turns NO and every method fails with
//   `OACErrorProfileUnavailable`.

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class OACSiteSettings;
@class OACDownloads;
@class OACExtensions;

/// Kinds of stored browsing data, for `-clearBrowsingDataOfTypes:...`.
typedef NS_OPTIONS(NSUInteger, OACBrowsingDataTypes) {
    OACBrowsingDataTypeHistory = 1 << 0,
    OACBrowsingDataTypeCookies = 1 << 1,
    OACBrowsingDataTypeCache = 1 << 2,
    OACBrowsingDataTypeSiteStorage = 1 << 3,
    OACBrowsingDataTypeDownloadsList = 1 << 4,
    OACBrowsingDataTypePasswords = 1 << 5,
    OACBrowsingDataTypeAutofill = 1 << 6,
    OACBrowsingDataTypeSiteSettings = 1 << 7,
};

OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACProfile : NSObject

/// The model `Profile.id`. An off-the-record profile has its original profile's identifier.
@property (nonatomic, readonly, copy) NSUUID *identifier;

/// An incognito context: nothing reaches disk and it dies with its last tab.
@property (nonatomic, readonly, getter=isOffTheRecord) BOOL offTheRecord;

/// NO once Chromium has destroyed the profile.
@property (nonatomic, readonly, getter=isValid) BOOL valid;

/// `<userDataDirectory>/Profiles/<identifier>`; nil for an off-the-record profile.
@property (nonatomic, readonly, copy, nullable) NSURL *dataDirectory;

/// For an off-the-record profile, the profile it derives from; nil otherwise.
@property (nonatomic, readonly, nullable) OACProfile *originalProfile NS_SWIFT_NAME(originalProfile);

/// The off-the-record variant, created on first use. Calling it on an off-the-record profile
/// returns the receiver.
@property (nonatomic, readonly) OACProfile *offTheRecordProfile NS_SWIFT_NAME(offTheRecordProfile);

/// Whether the off-the-record variant exists right now (without creating it).
@property (nonatomic, readonly) BOOL hasOffTheRecordProfile;

/// Per-site permissions, zoom, cookies (Site Control Center, `SiteSettingsProvider`).
@property (nonatomic, readonly) OACSiteSettings *siteSettings;

/// The profile's downloads (Library ▸ Downloads). Skeleton for plan C12.
@property (nonatomic, readonly) OACDownloads *downloads;

/// The profile's extensions. Skeleton for plan C14. Off-the-record profiles share the original's
/// extensions; only those allowed in incognito run there.
@property (nonatomic, readonly) OACExtensions *extensions;

/// Removes stored data of `types` written since `since` (nil: all time). inferred: the spec
/// records no Clear Browsing Data surface, Chromium's chrome://settings page covers it until one is
/// designed.
- (void)clearBrowsingDataOfTypes:(OACBrowsingDataTypes)types
                           since:(nullable NSDate *)since
               completionHandler:(void (^)(void))completionHandler;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
