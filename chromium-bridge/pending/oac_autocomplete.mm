// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// History search and search suggestions for the command bar (plan B66). See
// OACAutocomplete.h.
//
// STAGED SOURCE (plan B66). This file belongs at
// //openarc/bridge/oac_autocomplete.mm in the Chromium tree; it is kept here
// until the main session commits it on openarc/156 (see
// chromium-bridge/README.md §Command bar history and suggestions for the
// exact steps). It has not been compiled yet.
//
// Why not AutocompleteController: the omnibox stack wants a TemplateURLService
// default search provider, an AutocompleteProviderClient and Chrome's
// classification / scoring; the shell already owns the search engine choice
// (ProfileSettings.searchEngine) and the ranking (CommandBarRanker). So the
// bridge hands over raw data only:
// - history: HistoryService::QueryHistory with a text query (word match on
//   title and URL, REMOVE_ALL_DUPLICATES), then the URL rows' visit and typed
//   counts;
// - suggestions: one SimpleURLLoader GET on the profile's storage partition
//   (the OTR partition for an incognito profile), credentials omitted.

#import <OpenArcCore/OACAutocomplete.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/time/time.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "content/public/browser/storage_partition.h"
#include "net/base/load_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/base/apple/url_conversions.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

#import "openarc/bridge/oac_application_internal.h"
#import "openarc/bridge/oac_profile_internal.h"

namespace {

using HistoryHandler = void (^)(NSArray<OACHistoryEntry*>*);
using SuggestHandler = void (^)(NSData*);

// Own values (the spec records none): a suggestion that arrives later than
// this no longer helps the row list; the shell asks again on the next key.
constexpr base::TimeDelta kSuggestTimeout = base::Milliseconds(1500);
constexpr size_t kMaxSuggestBodySize = 64 * 1024;
constexpr int kMaxHistoryCount = 100;

net::NetworkTrafficAnnotationTag SuggestAnnotation() {
  return net::DefineNetworkTrafficAnnotation("openarc_search_suggestions", R"(
    semantics {
      sender: "Open Arc command bar"
      description:
        "Asks the user's search engine for query suggestions while the "
        "user types in the command bar."
      trigger:
        "Typing in the command bar, when 'Include search engine "
        "suggestions' is on for the profile."
      data: "The text typed so far."
      destination: OTHER
      destination_other: "The search engine chosen in the profile's settings."
    }
    policy {
      cookies_allowed: NO
      setting:
        "Settings > Profiles > Include search engine suggestions."
      policy_exception_justification: "Not implemented."
    })");
}

}  // namespace

@implementation OACHistoryEntry {
  NSURL* _URL;
  NSString* _title;
  NSDate* _lastVisitDate;
  NSInteger _visitCount;
  NSInteger _typedCount;
}

- (instancetype)initWithURL:(NSURL*)url
                      title:(NSString*)title
                  lastVisit:(NSDate*)lastVisit
                     visits:(NSInteger)visits
                      typed:(NSInteger)typed {
  if ((self = [super init])) {
    _URL = [url copy];
    _title = [title copy];
    _lastVisitDate = [lastVisit copy];
    _visitCount = MAX(1, visits);
    _typedCount = MAX(0, typed);
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  return self;  // Immutable.
}

- (NSURL*)URL {
  return _URL;
}
- (NSString*)title {
  return _title;
}
- (NSDate*)lastVisitDate {
  return _lastVisitDate;
}
- (NSInteger)visitCount {
  return _visitCount;
}
- (NSInteger)typedCount {
  return _typedCount;
}

@end

// One request. Owns the history task tracker or the URL loader; dropping them
// cancels the work. The handler runs once, from a posted task.
@implementation OACAutocompleteRequest {
  HistoryHandler _historyHandler;
  SuggestHandler _suggestHandler;
  std::unique_ptr<base::CancelableTaskTracker> _tracker;
  std::unique_ptr<network::SimpleURLLoader> _loader;
  BOOL _finished;
}

- (instancetype)initWithHistoryHandler:(HistoryHandler)historyHandler
                        suggestHandler:(SuggestHandler)suggestHandler {
  if ((self = [super init])) {
    _historyHandler = [historyHandler copy];
    _suggestHandler = [suggestHandler copy];
  }
  return self;
}

- (void)finishWithEntries:(NSArray<OACHistoryEntry*>*)entries body:(NSData*)body {
  if (_finished) {
    return;
  }
  _finished = YES;
  _tracker.reset();  // Cancels a pending history task.
  _loader.reset();   // Cancels a pending load.
  HistoryHandler history = _historyHandler;
  SuggestHandler suggest = _suggestHandler;
  _historyHandler = nil;
  _suggestHandler = nil;
  OACPostToMainThread(^{
    if (history) {
      history(entries ?: @[]);
    }
    if (suggest) {
      suggest(body);
    }
  });
}

- (void)cancel {
  CHECK(NSThread.isMainThread);
  [self finishWithEntries:@[] body:nil];
}

- (void)startHistoryQuery:(history::HistoryService*)service
                     text:(NSString*)text
                    count:(int)count {
  _tracker = std::make_unique<base::CancelableTaskTracker>();
  history::QueryOptions options;
  options.max_count = count;
  options.duplicate_policy = history::QueryOptions::REMOVE_ALL_DUPLICATES;
  options.policy_for_404_visits = history::VisitQuery404sPolicy::kExclude404s;
  __weak OACAutocompleteRequest* weakSelf = self;
  service->QueryHistory(
      base::SysNSStringToUTF16(text), options,
      base::BindOnce(^(history::QueryResults results) {
        OACAutocompleteRequest* request = weakSelf;
        if (!request) {
          return;
        }
        NSMutableArray<OACHistoryEntry*>* entries = [NSMutableArray array];
        for (const history::URLResult& row : results) {
          const GURL& url = row.url();
          if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
            continue;
          }
          NSURL* nsURL = net::NSURLWithGURL(url);
          if (!nsURL) {
            continue;
          }
          base::Time last = row.last_visit().is_null() ? row.visit_time()
                                                       : row.last_visit();
          [entries addObject:[[OACHistoryEntry alloc]
                                 initWithURL:nsURL
                                       title:base::SysUTF16ToNSString(row.title())
                                   lastVisit:last.ToNSDate()
                                      visits:row.visit_count()
                                       typed:row.typed_count()]];
        }
        [request finishWithEntries:entries body:nil];
      }),
      _tracker.get());
}

- (void)startFetch:(const GURL&)url profile:(Profile*)profile {
  auto resource = std::make_unique<network::ResourceRequest>();
  resource->url = url;
  resource->method = "GET";
  resource->credentials_mode = network::mojom::CredentialsMode::kOmit;
  // Nothing of the typed text stays behind: no cookies, no HTTP cache entry
  // (this also makes the on-disk context safe for an incognito window that
  // has no off-the-record context yet, see ChromiumAutocomplete.swift).
  resource->load_flags =
      net::LOAD_DO_NOT_SAVE_COOKIES | net::LOAD_DISABLE_CACHE;
  _loader = network::SimpleURLLoader::Create(std::move(resource),
                                             SuggestAnnotation());
  _loader->SetTimeoutDuration(kSuggestTimeout);
  scoped_refptr<network::SharedURLLoaderFactory> factory =
      profile->GetDefaultStoragePartition()
          ->GetURLLoaderFactoryForBrowserProcess();
  __weak OACAutocompleteRequest* weakSelf = self;
  network::SimpleURLLoader* loader = _loader.get();
  loader->DownloadToString(
      factory.get(),
      base::BindOnce(^(std::optional<std::string> body) {
        OACAutocompleteRequest* request = weakSelf;
        if (!request) {
          return;
        }
        NSData* data = nil;
        const network::mojom::URLResponseHead* head =
            loader->ResponseInfo();
        const int status =
            head && head->headers ? head->headers->response_code() : 0;
        if (body && status >= 200 && status < 300) {
          data = [NSData dataWithBytes:body->data() length:body->size()];
        }
        [request finishWithEntries:nil body:data];
      }),
      kMaxSuggestBodySize);
}

@end

@implementation OACProfile (OACAutocomplete)

- (OACAutocompleteRequest*)
    queryHistoryMatchingText:(NSString*)text
                maximumCount:(NSInteger)maximumCount
           completionHandler:(void (^)(NSArray<OACHistoryEntry*>*))completionHandler {
  CHECK(NSThread.isMainThread);
  CHECK(completionHandler);
  OACAutocompleteRequest* request =
      [[OACAutocompleteRequest alloc] initWithHistoryHandler:completionHandler
                                              suggestHandler:nil];
  NSString* trimmed = [text
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  Profile* profile = self.valid && !self.offTheRecord ? self.chromeProfile : nullptr;
  history::HistoryService* service =
      profile ? HistoryServiceFactory::GetForProfile(
                    profile, ServiceAccessType::EXPLICIT_ACCESS)
              : nullptr;
  if (trimmed.length == 0 || !service) {
    [request finishWithEntries:@[] body:nil];
    return request;
  }
  const int count = static_cast<int>(
      MIN(MAX(maximumCount, NSInteger{1}), NSInteger{kMaxHistoryCount}));
  [request startHistoryQuery:service text:trimmed count:count];
  return request;
}

- (OACAutocompleteRequest*)
    fetchSearchSuggestionsFromURL:(NSURL*)suggestionURL
                completionHandler:(void (^)(NSData*))completionHandler {
  CHECK(NSThread.isMainThread);
  CHECK(completionHandler);
  OACAutocompleteRequest* request =
      [[OACAutocompleteRequest alloc] initWithHistoryHandler:nil
                                              suggestHandler:completionHandler];
  Profile* profile = self.valid ? self.chromeProfile : nullptr;
  GURL url = net::GURLWithNSURL(suggestionURL);
  if (!profile || !url.is_valid() || !url.SchemeIs(url::kHttpsScheme)) {
    [request finishWithEntries:nil body:nil];
    return request;
  }
  [request startFetch:url profile:profile];
  return request;
}

@end
