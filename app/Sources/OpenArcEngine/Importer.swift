import Foundation
import OpenArcModel

// Importing history and saved passwords from another browser (plan D3b; bridge: OACImport.h).
// [01 §Arc] observed the menu item "Import from Another Browser…"; [00] records the import wizard
// as not captured, so the sources, kinds and messages are inferred. Bookmarks stay in the shell
// (`OpenArcImport`, plan D3): they become sidebar items, not engine bookmarks.

/// Where an import reads from.
public enum EngineImportSource: Hashable, Sendable {
    /// A Chromium-family profile folder (`…/Google/Chrome/Default`) and the keychain item that holds
    /// the browser's password key (service "Chrome Safe Storage", account "Chrome"). Reading that
    /// item makes macOS ask the user once.
    case chromiumProfile(directory: URL, keychainService: String, keychainAccount: String)
    /// Safari's library folder (`~/Library/Safari`): history only, and only with Full Disk Access.
    case safari(libraryDirectory: URL)
    /// An export file: Safari's ZIP (File ▸ Export Browsing Data…), a passwords CSV or a Safari
    /// history JSON.
    case exportFile(URL)
}

/// Kinds of data the engine imports.
public struct EngineImportKinds: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let history = EngineImportKinds(rawValue: 1 << 0)
    public static let passwords = EngineImportKinds(rawValue: 1 << 1)
}

/// What happened to one kind of data.
public enum EngineImportStatus: Hashable, Sendable {
    /// Not asked for.
    case notRequested
    /// Imported (the count may be 0 when the source had nothing new).
    case success
    /// The source has no such data.
    case notFound
    /// macOS refused to open the file: Safari's data needs Full Disk Access.
    case permissionDenied
    /// The browser's password key could not be read from the keychain (denied or missing).
    case keychainDenied
    /// Passwords were found but none could be decrypted.
    case decryptionFailed
    /// The file is damaged, too large or of an unknown format.
    case unreadable
    /// The profile cannot take imports (off the record, gone, or no engine).
    case unavailable
}

/// The outcome of `EngineImporter.importData`.
public struct EngineImportResult: Hashable, Sendable {
    public var historyStatus: EngineImportStatus
    /// Pages added to the profile's history.
    public var historyCount: Int
    public var passwordStatus: EngineImportStatus
    /// Logins now saved from this source (including ones that were already saved identically).
    public var passwordCount: Int
    /// Logins left out because another password is saved for that site and username (kept).
    public var passwordConflicts: Int
    /// Logins left out because they could not be decrypted or are invalid.
    public var passwordFailures: Int

    public init(
        historyStatus: EngineImportStatus = .notRequested, historyCount: Int = 0,
        passwordStatus: EngineImportStatus = .notRequested, passwordCount: Int = 0,
        passwordConflicts: Int = 0, passwordFailures: Int = 0
    ) {
        self.historyStatus = historyStatus
        self.historyCount = historyCount
        self.passwordStatus = passwordStatus
        self.passwordCount = passwordCount
        self.passwordConflicts = passwordConflicts
        self.passwordFailures = passwordFailures
    }

    /// Every requested kind reports `status`.
    public static func all(_ status: EngineImportStatus, for kinds: EngineImportKinds) -> EngineImportResult {
        EngineImportResult(
            historyStatus: kinds.contains(.history) ? status : .notRequested,
            passwordStatus: kinds.contains(.passwords) ? status : .notRequested
        )
    }
}

/// Imports into a profile's engine data (`-[OACProfile importDataOfTypes:fromSource:…]`). History
/// lands in the profile's history (visits marked as imported); passwords in its password store,
/// skipping duplicates and keeping a saved login whose password differs.
public protocol EngineImporter: AnyObject, Sendable {
    /// Which kinds this engine can import at all (empty: no importer).
    var supportedKinds: EngineImportKinds { get }
    /// Imports `kinds` from `source` into the on-disk profile `profileID`. Never throws: each kind
    /// reports its own status.
    func importData(_ kinds: EngineImportKinds, from source: EngineImportSource, into profileID: Profile.ID) async -> EngineImportResult
}

/// An engine without an importer (test doubles that do not provide one).
public final class UnavailableImporter: EngineImporter {
    public static let shared = UnavailableImporter()
    public init() {}
    public var supportedKinds: EngineImportKinds { [] }
    public func importData(_ kinds: EngineImportKinds, from source: EngineImportSource, into profileID: Profile.ID) async -> EngineImportResult {
        .all(.unavailable, for: kinds)
    }
}

/// Fake importer: answers with `nextResult` (default: every requested kind succeeds with 0 items)
/// and records each request.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeImporter: EngineImporter, @unchecked Sendable {
    public struct Request: Hashable, Sendable {
        public var kinds: EngineImportKinds
        public var source: EngineImportSource
        public var profileID: Profile.ID
    }

    private let lock = NSLock()
    private var log: [Request] = []
    private var result: EngineImportResult?

    public init() {}

    public var supportedKinds: EngineImportKinds { [.history, .passwords] }
    /// Requests received, oldest first.
    public var requests: [Request] { lock.withLock { log } }
    /// The answer to the next requests; nil: success with 0 items for each requested kind.
    public var nextResult: EngineImportResult? {
        get { lock.withLock { result } }
        set { lock.withLock { result = newValue } }
    }

    public func importData(_ kinds: EngineImportKinds, from source: EngineImportSource, into profileID: Profile.ID) async -> EngineImportResult {
        lock.withLock {
            log.append(Request(kinds: kinds, source: source, profileID: profileID))
            return result ?? .all(.success, for: kinds)
        }
    }
}
