// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACAutocomplete: browsing history search and search suggestions for the command bar (plan B66).
//
// Spec: docs/arc-spec/05-surfaces.md §command bar (observed: one entry for new tabs, search and
// commands), 07-design-system.md §9 (observed row glyphs: globe, magnifier, clock), 06-flows.md
// §16.2 / §19.1 / §23 (observed: a typed word without a matching command lists search
// suggestions), 03-settings.md §Profiles (observed: "Search engine", "Include search engine
// suggestions" per profile).
//
// Maps to: `EngineAutocomplete` (app/Sources/OpenArcEngine/Autocomplete.swift), wrapped by
// app/Sources/OpenArcChromium/ChromiumAutocomplete.swift. The bridge hands over raw data; the
// shell ranks and draws the rows (Chromium's omnibox UI and `AutocompleteController` are not used:
// the search engine choice lives in the shell's model, not in Chromium's TemplateURLService).
//
// - History: the profile's `history::HistoryService::QueryHistory` (title and URL word match,
//   one row per URL, newest visit first), with each row's visit and typed counts. An
//   off-the-record profile records no history, so it always answers an empty list.
// - Most visited (plan B123): `history::HistoryService::QueryMostVisitedURLs`, for an empty or
//   short command bar.
// - Suggestions: one GET of a suggestion URL the shell built from the profile's search engine,
//   through the profile's own network context (the off-the-record one for an incognito profile),
//   without cookies (none sent, none stored), without the HTTP cache, a 1.5 s timeout and a
//   64 KiB body limit. The body goes back unparsed; the shell reads the OpenSearch suggestion JSON
//   (`SearchSuggestionParser`).
//
// Both calls return a request object. `-cancel` stops the work (the history task is cancelled, the
// network load is dropped); if the handler has not run yet it then runs once with an empty result.
// The handler always runs exactly once, on the main thread, from a posted task.

#import <OpenArcCore/OACDefines.h>
#import <OpenArcCore/OACProfile.h>

NS_ASSUME_NONNULL_BEGIN

/// One page of the profile's history. Immutable.
OAC_EXPORT NS_SWIFT_SENDABLE
@interface OACHistoryEntry : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSURL *URL;
/// The stored page title; empty when the page had none.
@property (nonatomic, readonly, copy) NSString *title;
/// The most recent visit.
@property (nonatomic, readonly, copy) NSDate *lastVisitDate;
/// Visits recorded for the URL (at least 1).
@property (nonatomic, readonly) NSInteger visitCount;
/// Visits that came from typing the address (Chromium's typed count).
@property (nonatomic, readonly) NSInteger typedCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// A running history query or suggestion fetch.
OAC_EXPORT NS_SWIFT_UI_ACTOR
@interface OACAutocompleteRequest : NSObject
/// Stops the work. The handler, if it has not run yet, runs once with an empty result. Idempotent.
- (void)cancel;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface OACProfile (OACAutocomplete)

/// Pages whose title or URL contains every word of `text` (Chromium's history word match), one per
/// URL, newest visit first, at most `maximumCount` (1...100; other values are clamped). Only http
/// and https pages. An empty `text`, an off-the-record or invalid profile answer an empty array.
- (OACAutocompleteRequest *)queryHistoryMatchingText:(NSString *)text
                                        maximumCount:(NSInteger)maximumCount
                                   completionHandler:(void (^)(NSArray<OACHistoryEntry *> *entries))completionHandler
    NS_SWIFT_NAME(queryHistory(matching:maximumCount:completionHandler:));

/// The profile's most visited pages (plan B123): Chromium's history "most visited" query (the
/// data behind Chrome's new-tab tiles: pages reached by typing or from bookmarks, and the visits
/// that followed them, ranked by visit frequency and recency), at most `maximumCount` (1...100;
/// other values are clamped), best first, one per URL, http and https only. `visitCount` is the
/// page's visit count; `typedCount` is 0 (the query does not report it). An off-the-record or
/// invalid profile answers an empty array.
- (OACAutocompleteRequest *)queryMostVisitedWithMaximumCount:(NSInteger)maximumCount
                                           completionHandler:(void (^)(NSArray<OACHistoryEntry *> *entries))completionHandler
    NS_SWIFT_NAME(queryMostVisited(maximumCount:completionHandler:));

/// GETs `suggestionURL` (https only) through this profile's network context and answers the body,
/// or nil on any failure: not https, network error, non-2xx status, timeout (1.5 s), a body over
/// 64 KiB, an invalid profile, or cancellation. No cookies are sent or stored, and the HTTP cache
/// is not used.
- (OACAutocompleteRequest *)fetchSearchSuggestionsFromURL:(NSURL *)suggestionURL
                                        completionHandler:(void (^)(NSData *_Nullable body))completionHandler
    NS_SWIFT_NAME(fetchSearchSuggestions(from:completionHandler:));

@end

NS_ASSUME_NONNULL_END
