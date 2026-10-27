// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Page translation (plan B47): Chromium's translate component on the bridge's tabs, drawn by the
// shell.
//
// Maps to: `BrowserTabState.translation` (`PageTranslation`), `TabEvent.translationChanged`, the
// translation commands of `BrowserTab` and `BrowserEngine.resetTranslationDecisions`
// (app/Sources/OpenArcEngine/BrowserEngine.swift).
//
// Why shell-drawn (README §Keeping //chrome without its UI): Chrome keeps deciding WHEN a page can
// be translated (`TranslateManager`: the page language from the renderer, the target language from
// the user's languages, the never-translate lists) and does the translating (`TranslateAgent`
// runs Google's Translate Element script in an isolated world). It draws its offer, progress and
// "translated" bubble with Views anchored to a Browser window. The bridge replaces only that view
// (Chrome's `TranslateBubbleFactory` hook, which Chrome uses whenever no Browser holds the tab) and
// reports a state per tab; the shell draws Arc's surfaces ([06 §19] observed: a second line in the
// URL box, an offer bubble, an Options menu, no progress UI, no Site Control Center entry).
//
// Service: Chrome offers translation only with Google API keys (none in this build). The bridge
// lifts that gate; the translation itself runs through the Translate Element library Google serves
// to websites (translate.googleapis.com), which works without a key of ours (README §Translation).
// A failure (offline, the service refusing) reaches the shell as `OACTranslationStatusFailed`.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACApplication.h>
#import <OpenArcCore/OACProfile.h>
#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a tab stands with respect to translation. Maps to `PageTranslation.Status`.
typedef NS_ENUM(NSInteger, OACTranslationStatus) {
    /// Nothing to offer: the page is in one of the user's languages, its language is unknown, the
    /// site or language is on a never-translate list, or the page cannot be translated (internal
    /// pages, off-the-record detection gaps).
    OACTranslationStatusNone = 0,
    /// The page can be translated ("Translation Available", [06 §19.1] observed).
    OACTranslationStatusAvailable = 1,
    /// A translation was requested and has not finished (script download, then the page).
    OACTranslationStatusTranslating = 2,
    /// The page shows the translation ("Translated", [06 §19.4] observed).
    OACTranslationStatusTranslated = 3,
    /// The last translation failed (`error`).
    OACTranslationStatusFailed = 4,
};

/// Why a translation failed (Chromium's `translate::TranslateErrors`).
typedef NS_ENUM(NSInteger, OACTranslationError) {
    OACTranslationErrorNone = 0,
    /// No connection, or the translate script could not be downloaded.
    OACTranslationErrorNetwork = 1,
    /// The translate library did not start (the service refused it, a page policy blocked it).
    OACTranslationErrorInitialization = 2,
    /// The page's language could not be detected.
    OACTranslationErrorUnknownLanguage = 3,
    /// The service does not support the page's language.
    OACTranslationErrorUnsupportedLanguage = 4,
    /// The page is already in the target language.
    OACTranslationErrorIdenticalLanguages = 5,
    /// The service reported an error while translating.
    OACTranslationErrorTranslation = 6,
    /// The library did not finish in time.
    OACTranslationErrorTimeout = 7,
    /// Any other script failure.
    OACTranslationErrorScript = 8,
};

/// A language the translate service knows: a BCP 47 code ("de", "zh-CN") and its name in the
/// engine's UI language ("German", "Chinese (Simplified)").
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACTranslationLanguage : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *code;
@property (nonatomic, readonly, copy) NSString *name;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Immutable snapshot of a tab's translation state.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACTranslationState : NSObject <NSCopying>
@property (nonatomic, readonly) OACTranslationStatus status;
/// For `OACTranslationStatusFailed`; `OACTranslationErrorNone` otherwise.
@property (nonatomic, readonly) OACTranslationError error;
/// The page's original language; nil while unknown.
@property (nonatomic, readonly, copy, nullable) OACTranslationLanguage *sourceLanguage;
/// The language the page is (or would be) translated into: the current translation's language
/// once translated, else Chrome's target language for the user (the UI language or one of the
/// user's languages). nil while unknown.
@property (nonatomic, readonly, copy, nullable) OACTranslationLanguage *targetLanguage;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// Translation of one tab. Changes reach `-[OACTabDelegate tabDidChangeTranslationState:]`.
@interface OACTab (OACTranslation)
/// Current state; a new object after every change.
@property (nonatomic, readonly, copy) OACTranslationState *translationState;
/// Translates the page into `languageCode` (nil: the state's `targetLanguage`), as Chrome's
/// bubble "Translate" button does (it also counts the acceptance for Chrome's heuristics). Does
/// nothing while the page language is unknown or the tab is closed. Also retries after a failure.
- (void)translateToLanguage:(nullable NSString *)languageCode NS_SWIFT_NAME(translate(toLanguage:));
/// Shows the original page again. Does nothing when the page is not translated.
- (void)revertTranslation;
/// Puts the page's site on the profile's never-translate list ([06 §19.3] observed "Never
/// Translate This Site"), reverts a translated page and withdraws the offer: the state turns
/// `OACTranslationStatusNone` until the list is reset (`-[OACProfile resetTranslationSettings]`).
- (void)neverTranslateSite;
@end

@interface OACProfile (OACTranslation)
/// Forgets every translation decision of the profile: never-translate sites and languages (back
/// to Chrome's default: the UI language), always-translate languages and the accept / decline
/// counts (Chrome's `TranslatePrefs::ResetToDefaults`). Settings ▸ Advanced "Reset Translated-site
/// Prompts" ([03 §Advanced] observed button). Pages loaded afterwards are offered again.
- (void)resetTranslationSettings;
@end

@interface OACApplication (OACTranslation)
/// Every language the service can translate into, sorted by name ([06 §19.3] observed "Choose
/// Another Language ▸": alphabetical, Afrikaans to Zulu). Empty before the engine started.
@property (nonatomic, readonly, copy) NSArray<OACTranslationLanguage *> *translationTargetLanguages;
@end

NS_ASSUME_NONNULL_END
