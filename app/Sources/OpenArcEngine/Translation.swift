import Foundation
import OpenArcModel

// Page translation (plan B47; bridge: OACTranslation.h). The engine decides when a page can be
// translated (its language detection, the user's languages, the never-translate lists) and
// translates it; the shell draws Arc's surfaces. [06 §19] observed (Arc 1.170.0):
// - No translate bar and no automatic bubble: a second line in the sidebar URL box reads
//   "Translation Available" (19.1); with the toolbar on, an icon button "Translation Options" left
//   of the Site Control Center button takes its place.
// - Clicking it shows "Translate this page to <target>?" with Options and Translate (19.2).
// - No progress UI: the line stays "Translation Available" while translating, then reads
//   "Translated" (19.4).
// - "Use Original" reverts and shows "Translated back to <source>! Use ⌘Z to undo." for about 4 s;
//   ⌘Z translates again (19.5).
// - No translation entry in the Site Control Center or the command bar (19.1).

/// A language the translate service knows.
public struct TranslationLanguage: Hashable, Sendable {
    /// BCP 47 code as the engine uses it ("de", "zh-CN").
    public var code: String
    /// Name in the UI language ("German").
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// Where a tab stands with respect to translation (`BrowserTabState.translation`).
public struct PageTranslation: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Nothing to offer (a language the user reads, an unknown language, a never-translate
        /// site, an internal page).
        case unavailable
        /// The page can be translated. [06 §19.1] observed "Translation Available".
        case available
        /// A translation is running. [06 §19.4] observed: Arc shows no progress UI for it.
        case translating
        /// The page shows the translation. [06 §19.4] observed "Translated".
        case translated
        /// The last translation failed. The spec records no failure UI ([06 §19.6]: unknown).
        case failed(TranslationFailure)
    }

    public var status: Status
    /// The page's original language; nil while unknown.
    public var sourceLanguage: TranslationLanguage?
    /// The language of the current translation once translated, else the one the offer proposes
    /// (the UI language for most users; [06 §19.2] observed "English", the UI language).
    public var targetLanguage: TranslationLanguage?

    public init(status: Status, sourceLanguage: TranslationLanguage? = nil, targetLanguage: TranslationLanguage? = nil) {
        self.status = status
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    public static let unavailable = PageTranslation(status: .unavailable)

    /// The shell offers its translation entry (URL box line, toolbar button). A failed attempt keeps
    /// the entry so the user can try again (inferred; [06 §19.6] failure states not captured).
    public var hasEntry: Bool { status != .unavailable }
}

/// Why a translation failed (Chromium's translate errors, folded).
public enum TranslationFailure: String, Hashable, Sendable {
    /// No connection, or the translate script could not be downloaded.
    case network
    /// The translate service refused to start (for example without a usable key).
    case serviceUnavailable
    case unknownLanguage
    case unsupportedLanguage
    case identicalLanguages
    /// The service reported an error, or did not finish in time.
    case translationFailed
}

/// Page translation of every profile (`BrowserEngine.translation`).
public protocol EngineTranslation: AnyObject, Sendable {
    /// Languages a page can be translated into, sorted by name. [06 §19.3] observed "Choose Another
    /// Language ▸": every target language, alphabetical (Afrikaans … Zulu).
    func targetLanguages() async -> [TranslationLanguage]
    /// Forgets the profile's translation decisions: never-translate sites and languages,
    /// always-translate languages, the accept / decline counts. Settings ▸ Advanced "Reset
    /// Translated-site Prompts" ([03 §Advanced] observed button; its effect is [06 §19.6] unknown,
    /// inferred from the name and the engine's prompt memory).
    func resetDecisions(profileID: Profile.ID) async
}

/// An engine without translation: no languages, nothing to reset. The default for engines that do
/// not provide it (test doubles).
public final class UnavailableTranslation: EngineTranslation {
    public static let shared = UnavailableTranslation()
    public init() {}
    public func targetLanguages() async -> [TranslationLanguage] { [] }
    public func resetDecisions(profileID: Profile.ID) async {}
}
