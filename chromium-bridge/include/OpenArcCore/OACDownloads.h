// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACDownloads: a profile's downloads. Skeleton for plan C12 ("downloads" in its row) and the
// Library's Downloads section ([06 §8] observed: search field "Search Downloads…", a "Filter"
// button, empty state "Nothing here yet!"; [01 §Window] observed "View Downloads…").
//
// Maps to: nothing in OpenArcEngine yet; proposed `EngineDownloads` (SWIFT_PROTOCOL_CHANGES.md §8).
// The Chromium side: the profile's `content::DownloadManager` with `//chrome`'s download core
// service (history-backed list, dangerous file checks, Safe Browsing off), and
// `DownloadManagerDelegate` replaced so Chromium's download bubble and shelf never appear.
//
// The download location comes from Settings ([03] observed "Download location", default
// Downloads): the shell sets `defaultDirectory`; the bridge never asks where to save unless
// `promptsForLocation` is YES.
//
// As built in C12: the profile's `content::DownloadManager` with //chrome's
// `ChromeDownloadManagerDelegate` (history-backed list, target paths, dangerous and insecure
// download checks, "ask where to save" through Chromium's native save panel when
// `promptsForLocation` is YES; Chrome turns that on for off-the-record profiles). Chrome's bubble
// never shows (it needs a Browser window). Items that are temporary or transient (Save Page As
// internals, extension downloads) are not listed.

#import <OpenArcCore/OACDefines.h>

NS_ASSUME_NONNULL_BEGIN

@class OACProfile;
@class OACDownloads;

typedef NS_ENUM(NSInteger, OACDownloadState) {
    OACDownloadStateInProgress = 0,
    OACDownloadStatePaused = 1,
    OACDownloadStateComplete = 2,
    OACDownloadStateCancelled = 3,
    OACDownloadStateInterrupted = 4,
    /// Waiting for the user to keep or discard a file Chromium flagged as dangerous.
    OACDownloadStateNeedsConfirmation = 5,
};

/// Immutable snapshot of one download.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACDownloadItem : NSObject <NSCopying>
/// Stable across launches (Chromium's download GUID).
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSURL *sourceURL;
/// The page the download started from, if any.
@property (nonatomic, readonly, copy, nullable) NSURL *referrerURL;
/// Final file location; nil until decided.
@property (nonatomic, readonly, copy, nullable) NSURL *fileURL;
@property (nonatomic, readonly, copy) NSString *suggestedFilename;
@property (nonatomic, readonly, copy, nullable) NSString *MIMEType;
@property (nonatomic, readonly) OACDownloadState state;
@property (nonatomic, readonly) int64_t receivedBytes;
/// -1 when unknown.
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly, copy) NSDate *startDate;
@property (nonatomic, readonly, copy, nullable) NSDate *endDate;
/// Started from an off-the-record profile (kept in memory only).
@property (nonatomic, readonly) BOOL isOffTheRecord;
/// For `OACDownloadStateNeedsConfirmation`: why ("This type of file can harm your computer",
/// "insecure download"), Chromium's wording. nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSString *warningText;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
@protocol OACDownloadsObserver <NSObject>
@optional
- (void)downloads:(OACDownloads *)downloads didAddItem:(OACDownloadItem *)item;
/// Progress is coalesced to at most a few updates per second.
- (void)downloads:(OACDownloads *)downloads didUpdateItem:(OACDownloadItem *)item;
- (void)downloads:(OACDownloads *)downloads didRemoveItemWithIdentifier:(NSString *)identifier;
@end

OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACDownloads : NSObject

@property (nonatomic, readonly, weak, nullable) OACProfile *profile;

/// Where files go. Set by the shell from the "Download location" setting.
@property (nonatomic, copy) NSURL *defaultDirectory;
/// Ask for a location for every download. Default NO.
@property (nonatomic) BOOL promptsForLocation;

/// Every download in the profile's history, newest first.
@property (nonatomic, readonly, copy) NSArray<OACDownloadItem *> *items;

- (void)pauseItemWithIdentifier:(NSString *)identifier;
- (void)resumeItemWithIdentifier:(NSString *)identifier;
- (void)cancelItemWithIdentifier:(NSString *)identifier;
/// For `OACDownloadStateNeedsConfirmation`: keep (YES) or discard (NO) the file.
- (void)confirmItemWithIdentifier:(NSString *)identifier keep:(BOOL)keep;
/// Removes the entry from the list (the file stays on disk).
- (void)removeItemWithIdentifier:(NSString *)identifier;
/// Starts a download without navigating (context menu "Download Linked File", Save Image As).
- (void)downloadURL:(NSURL *)url;

- (void)addObserver:(id<OACDownloadsObserver>)observer;
- (void)removeObserver:(id<OACDownloadsObserver>)observer;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
