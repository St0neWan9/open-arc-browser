import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineAutocomplete` (plan B66) on the bridge's OACAutocomplete.h:
// `-[OACProfile queryHistoryMatchingText:maximumCount:completionHandler:]` and
// `-[OACProfile fetchSearchSuggestionsFromURL:completionHandler:]`, both returning an
// `OACAutocompleteRequest` with `-cancel`.
//
// Capability check: framework builds from before B66 have neither method nor the
// `OACHistoryEntry` / `OACAutocompleteRequest` classes, so this file names none of them. It looks
// the selectors up at run time, calls them through their implementation pointers and reads the
// entries by key. On an old framework `capabilities` is empty and both calls answer nothing, so
// the command bar shows no history and no suggestions instead of crashing on an unrecognized
// selector. Once every framework in use has OACAutocomplete.h this can become direct calls.

final class ChromiumAutocomplete: EngineAutocomplete {
    static let historySelector = NSSelectorFromString("queryHistoryMatchingText:maximumCount:completionHandler:")
    static let suggestionsSelector = NSSelectorFromString("fetchSearchSuggestionsFromURL:completionHandler:")
    static let cancelSelector = NSSelectorFromString("cancel")
    /// Plan B123: `-[OACProfile queryMostVisitedWithMaximumCount:completionHandler:]`.
    static let mostVisitedSelector = NSSelectorFromString("queryMostVisitedWithMaximumCount:completionHandler:")

    private typealias HistoryHandler = @convention(block) (NSArray) -> Void
    private typealias HistoryFunction = @convention(c) (AnyObject, Selector, NSString, Int, HistoryHandler) -> AnyObject
    private typealias MostVisitedFunction = @convention(c) (AnyObject, Selector, Int, HistoryHandler) -> AnyObject
    private typealias SuggestionsHandler = @convention(block) (NSData?) -> Void
    private typealias SuggestionsFunction = @convention(c) (AnyObject, Selector, NSURL, SuggestionsHandler) -> AnyObject

    private let core: ChromiumEngineCore

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    /// What the loaded framework implements (instance methods of `OACProfile`).
    let capabilities: AutocompleteCapabilities = {
        var supported: AutocompleteCapabilities = []
        if OACProfile.instancesRespond(to: ChromiumAutocomplete.historySelector) { supported.insert(.history) }
        if OACProfile.instancesRespond(to: ChromiumAutocomplete.suggestionsSelector) { supported.insert(.searchSuggestions) }
        return supported
    }()

    func historyMatches(for text: String, profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capabilities.contains(.history), !trimmed.isEmpty, maxCount > 0, !Task.isCancelled,
              let profile = await core.onDiskProfile(profileID) else { return [] }
        let entries: [HistoryMatch] = await Self.cancellable { finish in
            Self.queryHistory(profile, text: trimmed, maxCount: maxCount) { array in
                finish(array.compactMap(Self.historyMatch))
            }
        } ?? []
        return HistoryMatch.sortedByFrecency(entries, now: Date())
    }

    func searchSuggestions(_ request: SearchSuggestionRequest) async -> [String] {
        await searchCompletionEntries(request).filter { !$0.isNavigation }.map(\.text)
    }

    /// Plan B128: the service's answer including its navigation rows. The bridge hands over the
    /// body unparsed (OACAutocomplete.h), so navigation rows need no bridge change.
    func searchCompletions(_ request: SearchSuggestionRequest) async -> [SearchSuggestion] {
        await searchCompletionEntries(request)
    }

    private func searchCompletionEntries(_ request: SearchSuggestionRequest) async -> [SearchSuggestion] {
        guard capabilities.contains(.searchSuggestions), let url = request.url, !Task.isCancelled,
              let onDisk = await core.onDiskProfile(request.profileID) else { return [] }
        let body: Data? = await Self.cancellable { finish in
            // An incognito window asks through its off-the-record context when one exists; before
            // its first tab there is none, and the bridge's request leaves no cookie or cache entry
            // behind in the on-disk context either (OACAutocomplete.h).
            let profile = request.isOffTheRecord && onDisk.hasOffTheRecordProfile ? onDisk.offTheRecordProfile : onDisk
            return Self.fetchSuggestions(profile, url: url) { data in finish(data.map { Data($0) }) }
        } ?? nil
        guard let body else { return [] }
        return SearchSuggestionParser.completions(from: body, query: request.query)
    }

    /// Plan B123: the history service's most visited pages (Chromium's top sites query), most
    /// visited first. A framework without the query (before B123) answers nothing.
    func topSites(profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] {
        guard capabilities.contains(.history), maxCount > 0, !Task.isCancelled,
              OACProfile.instancesRespond(to: Self.mostVisitedSelector),
              let profile = await core.onDiskProfile(profileID) else { return [] }
        let entries: [HistoryMatch] = await Self.cancellable { finish in
            Self.queryMostVisited(profile, maxCount: maxCount) { array in
                finish(array.compactMap(Self.historyMatch))
            }
        } ?? []
        return HistoryMatch.sortedByVisits(entries)
    }

    // MARK: Bridge calls by selector

    @MainActor
    private static func queryMostVisited(_ profile: OACProfile, maxCount: Int, handler: @escaping (NSArray) -> Void) -> AnyObject? {
        guard let implementation = profile.method(for: mostVisitedSelector) else {
            handler([])
            return nil
        }
        let call = unsafeBitCast(implementation, to: MostVisitedFunction.self)
        let block: HistoryHandler = { array in handler(array) }
        return call(profile, mostVisitedSelector, maxCount, block)
    }

    @MainActor
    private static func queryHistory(_ profile: OACProfile, text: String, maxCount: Int, handler: @escaping (NSArray) -> Void) -> AnyObject? {
        guard let implementation = profile.method(for: historySelector) else {
            handler([])
            return nil
        }
        let call = unsafeBitCast(implementation, to: HistoryFunction.self)
        let block: HistoryHandler = { array in handler(array) }
        return call(profile, historySelector, text as NSString, maxCount, block)
    }

    @MainActor
    private static func fetchSuggestions(_ profile: OACProfile, url: URL, handler: @escaping (NSData?) -> Void) -> AnyObject? {
        guard let implementation = profile.method(for: suggestionsSelector) else {
            handler(nil)
            return nil
        }
        let call = unsafeBitCast(implementation, to: SuggestionsFunction.self)
        let block: SuggestionsHandler = { data in handler(data) }
        return call(profile, suggestionsSelector, url as NSURL, block)
    }

    /// An `OACHistoryEntry`, read by key (the class is not in older headers).
    private static func historyMatch(_ object: Any) -> HistoryMatch? {
        guard let entry = object as? NSObject,
              let url = entry.value(forKey: "URL") as? URL,
              let lastVisit = entry.value(forKey: "lastVisitDate") as? Date else { return nil }
        return HistoryMatch(
            url: url,
            title: entry.value(forKey: "title") as? String ?? "",
            lastVisit: lastVisit,
            visitCount: (entry.value(forKey: "visitCount") as? Int) ?? 1,
            typedCount: (entry.value(forKey: "typedCount") as? Int) ?? 0
        )
    }

    /// Runs a bridge request on the main actor and waits for its handler. Cancelling the calling
    /// task sends `-cancel` to the request (the bridge then answers once with an empty result) and
    /// returns nil at once.
    private static func cancellable<T: Sendable>(
        _ start: @escaping @MainActor (_ finish: @escaping @Sendable (T) -> Void) -> AnyObject?
    ) async -> T? {
        let box = RequestBox<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard box.install(continuation) else { return }
                Task { @MainActor in
                    let request = start { value in box.resume(value) }
                    if let request, box.keep(request) == false {
                        // Cancelled while starting.
                        _ = (request as? NSObject)?.perform(cancelSelector)
                    }
                }
            }
        } onCancel: {
            if let request = box.cancel() {
                // The bridge is main-thread only. `request` is an `OACAutocompleteRequest` (ObjC,
                // main-actor object) passed across only to call `-cancel` on the main thread.
                let handle = UncheckedRequest(object: request)
                Task { @MainActor in _ = (handle.object as? NSObject)?.perform(cancelSelector) }
            }
        }
    }
}

/// Carries a bridge request object to the main actor for `-cancel`.
// @unchecked: the wrapped object is only touched on the main actor (the hop above); this struct
// only moves the reference.
private struct UncheckedRequest: @unchecked Sendable {
    let object: AnyObject
}

/// The continuation and bridge request of one call; resumed exactly once.
// @unchecked: every mutable stored property is read and written only under `lock`.
private final class RequestBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var request: AnyObject?
    private var isCancelled = false
    private var isDone = false

    /// Stores the continuation; false (and resumed with nil) when already cancelled.
    func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let cancelled: Bool = lock.withLock {
            if isCancelled { isDone = true; return true }
            self.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(returning: nil) }
        return !cancelled
    }

    /// Keeps the running request for a later cancel; false when the call was cancelled meanwhile.
    func keep(_ request: AnyObject) -> Bool {
        lock.withLock {
            if isCancelled { return false }
            if !isDone { self.request = request }
            return true
        }
    }

    func resume(_ value: T) {
        let continuation: CheckedContinuation<T?, Never>? = lock.withLock {
            guard !isDone else { return nil }
            isDone = true
            request = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }

    /// Marks the call cancelled, resumes the waiter with nil and hands back the request to cancel.
    func cancel() -> AnyObject? {
        let (continuation, request): (CheckedContinuation<T?, Never>?, AnyObject?) = lock.withLock {
            isCancelled = true
            guard !isDone else { return (nil, nil) }
            isDone = true
            defer { self.continuation = nil; self.request = nil }
            return (self.continuation, self.request)
        }
        continuation?.resume(returning: nil)
        return request
    }
}
