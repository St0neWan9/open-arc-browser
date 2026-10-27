// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Importing history and saved passwords from another browser into a profile (plan D3b).
//
// Spec: [01 §Arc] observed the menu item "Import from Another Browser…"; [00] lists the import
// wizard as not captured, so the sources, the data kinds and every message are inferred.
// Bookmarks stay in the shell (`OpenArcImport`, plan D3): they become sidebar items, not Chrome
// bookmarks.
//
// Maps to: `EngineImporter` (app/Sources/OpenArcEngine/EngineServices.swift).
//
// The Chromium side. Chromium has no importer for Chrome-family profiles (Chrome is the browser
// that imports), and its Safari history reader was removed when Safari moved to a database, so the
// bridge reads the sources itself and hands the data to //chrome's import writers:
// - History goes through `ProfileWriter::AddHistoryPage` (//chrome/browser/importer), Chrome's own
//   import path into the profile's `HistoryService` (visits marked as imported).
// - Passwords go through `password_manager::PasswordImporter`, the importer behind
//   chrome://password-manager's "Import passwords": duplicates are skipped, a saved login with the
//   same site and username but another password is kept (the imported one is dropped and counted
//   as a conflict), CSV files are parsed in Chromium's sandboxed CSV parser.
//
// Sources:
// - A Chromium-family profile folder (Chrome, Brave, Edge, Chromium, Vivaldi): its `History`
//   database, and `Login Data` plus `Login Data For Account`, whose passwords are decrypted with the
//   browser's "<Name> Safe Storage" keychain key. Reading that key is a keychain access to another
//   app's item, so macOS asks the user to allow it. With `--use-mock-keychain` (tests and the
//   development build) the key comes from Chromium's mock keychain instead, like Open Arc's own key.
// - Safari (`~/Library/Safari`): `History.db`. macOS lets an app read it only with Full Disk
//   Access; without it the result is `OACImportStatusPermissionDenied` (the bridge never asks for
//   the permission). Safari's passwords are in the system keychain and are not readable; they come
//   from Safari's export file instead.
// - An export file: the ZIP of Safari's File ▸ Export Browsing Data (its `Passwords.csv` and
//   `History*.json`), a passwords CSV (Safari, Chrome or another browser's export) or one Safari
//   history JSON file.
//
// Sources are copied to a temporary folder before reading (the browsers may be running and keep
// their databases locked); the copies are deleted afterwards. Nothing is written to the source.
// Only http and https pages visited in the last 90 days are imported (Chromium's history keeps no
// older visits).

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACProfile.h>

NS_ASSUME_NONNULL_BEGIN

/// The kinds of data an import brings over.
typedef NS_OPTIONS(NSUInteger, OACImportDataTypes) {
    OACImportDataTypeHistory = 1 << 0,
    OACImportDataTypePasswords = 1 << 1,
};

typedef NS_ENUM(NSInteger, OACImportSourceKind) {
    /// A Chromium-family browser's profile folder.
    OACImportSourceKindChromiumProfile = 0,
    /// Safari's library folder (`~/Library/Safari`).
    OACImportSourceKindSafari = 1,
    /// An export file (Safari's ZIP, a passwords CSV or a Safari history JSON).
    OACImportSourceKindExportFile = 2,
};

/// What happened to one kind of data.
typedef NS_ENUM(NSInteger, OACImportStatus) {
    /// Not asked for.
    OACImportStatusNotRequested = 0,
    /// Imported (the count may be 0 when the source had nothing new).
    OACImportStatusSuccess = 1,
    /// The source has no such data (no file, or the export has no such part).
    OACImportStatusNotFound = 2,
    /// macOS refused to open the file: Safari's data needs Full Disk Access.
    OACImportStatusPermissionDenied = 3,
    /// The browser's Safe Storage key could not be read from the keychain (denied or missing).
    OACImportStatusKeychainDenied = 4,
    /// Passwords were found but none could be decrypted with the key that was read.
    OACImportStatusDecryptionFailed = 5,
    /// The file is damaged, too large or not in a known format.
    OACImportStatusUnreadable = 6,
    /// The profile is off the record or went away before the import finished.
    OACImportStatusUnavailable = 7,
};

/// Where to import from. Immutable.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACImportSource : NSObject <NSCopying>
/// A Chromium-family profile folder (for example `…/Google/Chrome/Default`) and the keychain item
/// that holds the browser's password key (service "Chrome Safe Storage", account "Chrome").
+ (instancetype)chromiumProfileAtURL:(NSURL *)profileDirectory
                 keychainServiceName:(NSString *)serviceName
                 keychainAccountName:(NSString *)accountName
    NS_SWIFT_NAME(chromiumProfile(at:keychainServiceName:keychainAccountName:));
/// Safari's library folder, normally `~/Library/Safari`.
+ (instancetype)safariAtURL:(NSURL *)libraryDirectory NS_SWIFT_NAME(safari(at:));
/// An export file the user chose.
+ (instancetype)exportFileAtURL:(NSURL *)fileURL NS_SWIFT_NAME(exportFile(at:));

@property (nonatomic, readonly) OACImportSourceKind kind;
@property (nonatomic, readonly, copy) NSURL *URL;
/// Chromium profiles only; nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSString *keychainServiceName;
@property (nonatomic, readonly, copy, nullable) NSString *keychainAccountName;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// The outcome of `-importDataOfTypes:fromSource:completionHandler:`. Immutable.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACImportResult : NSObject <NSCopying>
@property (nonatomic, readonly) OACImportStatus historyStatus;
/// Pages added to the profile's history.
@property (nonatomic, readonly) NSInteger historyCount;
@property (nonatomic, readonly) OACImportStatus passwordStatus;
/// Logins now in the profile's password store from this source (also those that were already
/// saved there identically).
@property (nonatomic, readonly) NSInteger passwordCount;
/// Logins left out because the profile already saves another password for that site and username
/// (the saved one is kept).
@property (nonatomic, readonly) NSInteger passwordConflictCount;
/// Logins left out because they could not be decrypted or are not valid (no URL, too long, …).
@property (nonatomic, readonly) NSInteger passwordFailureCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface OACProfile (OACImport)

/// Imports `types` from `source` into this profile. Reading happens on Chromium's background
/// threads; the handler runs once on the main thread. An off-the-record profile reports
/// `OACImportStatusUnavailable` for every requested type.
- (void)importDataOfTypes:(OACImportDataTypes)types
               fromSource:(OACImportSource *)source
        completionHandler:(void (^)(OACImportResult *result))completionHandler
    NS_SWIFT_NAME(importData(ofTypes:from:completionHandler:));

@end

NS_ASSUME_NONNULL_END
