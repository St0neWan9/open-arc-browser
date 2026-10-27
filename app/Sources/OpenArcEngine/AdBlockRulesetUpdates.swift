import CryptoKit
import Foundation

// Ad-block filter-list updates from our static host (plan C19).
//
// The spec records the ad blocker as an inherited engine feature with a settings switch
// ([00 §A 内核继承] "广告拦截", observed) and says the merged filter rules are static content the
// project hosts itself ([00 §已定的服务策略], observed: GitHub Releases / Pages or R2). Everything
// below (manifest, signature, store layout, schedule) is our own design.
//
// The flow: fetch `manifest.json` and `manifest.json.sig` from the host, verify the Ed25519
// signature against the public key built into the app, check that the manifest is newer than what
// the engine uses, download the ruleset and its ATTRIBUTION, check size and SHA-256, write them
// into a new version directory of the store and swap the store's `Current` link to it. The caller
// then hands the directory to the engine, which indexes and publishes it without a restart
// (Chromium: `-[OACApplication loadAdBlockingRulesetFromDirectory:completionHandler:]`). Nothing
// here talks to the engine, so the whole path is testable without Chromium.
//
// The publishing side is `scripts/publish-adblock-ruleset.sh`; the format and the local test host
// are described in chromium-bridge/README.md §Ad blocking.

// MARK: - Manifest

/// The signed description of one published ruleset (`manifest.json` on the host).
///
/// ```json
/// {
///   "type": "org.openarc.adblock-ruleset",
///   "format": 1,
///   "serial": 202610271530,
///   "version": "20261027-e7d406ab505d",
///   "published": "2026-10-27T15:30:00Z",
///   "ruleset": { "path": "rulesets/20261027-e7d406ab505d/ruleset.pb", "size": 4059126, "sha256": "…" },
///   "attribution": { "path": "rulesets/20261027-e7d406ab505d/ATTRIBUTION", "size": 721, "sha256": "…" }
/// }
/// ```
///
/// The signature (`manifest.json.sig`, base64) covers the exact bytes of `manifest.json`, so no
/// JSON canonicalization is needed. `type` keeps a signature over some other document from passing
/// as a manifest; `serial` increases with every publish and protects against replaying an older,
/// genuinely signed manifest.
public struct AdBlockRulesetManifest: Codable, Sendable, Equatable {
    public static let typeIdentifier = "org.openarc.adblock-ruleset"
    public static let currentFormat = 1

    /// One file of the ruleset, relative to the manifest's URL.
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var size: Int
        /// Lowercase hex.
        public var sha256: String

        public init(path: String, size: Int, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var type: String
    public var format: Int
    public var serial: Int64
    public var version: String
    public var published: String?
    public var ruleset: File
    public var attribution: File

    public init(
        type: String = AdBlockRulesetManifest.typeIdentifier, format: Int = AdBlockRulesetManifest.currentFormat,
        serial: Int64, version: String, published: String? = nil, ruleset: File, attribution: File
    ) {
        self.type = type
        self.format = format
        self.serial = serial
        self.version = version
        self.published = published
        self.ruleset = ruleset
        self.attribution = attribution
    }
}

/// Why an update was not applied.
public enum AdBlockRulesetUpdateError: Error, Equatable, Sendable {
    /// The signature file is not base64 of 64 bytes, or no trusted key verifies it.
    case badSignature
    /// The manifest is not the JSON described above.
    case malformedManifest(String)
    /// `type` or `format` is not one this build understands.
    case unsupportedManifest
    /// `version` is not `<yyyymmdd>-<hex>` (it also names a directory).
    case invalidVersion(String)
    /// A file path is absolute, has a scheme, or leaves the host.
    case invalidPath(String)
    /// `serial` is not above the last accepted one (a replayed manifest).
    case replayedSerial(Int64)
    /// A file is larger than the limit, or its size differs from the manifest.
    case sizeMismatch(String)
    /// A file's SHA-256 differs from the manifest.
    case hashMismatch(String)
    /// Network or HTTP failure.
    case download(String)
    /// The store on disk could not be written.
    case store(String)
}

// MARK: - Versions

/// Ruleset versions as `chromium-bridge/build-adblock-ruleset.sh` writes them:
/// `<yyyymmdd>-<hex prefix of the ruleset's SHA-256>`.
public enum AdBlockRulesetVersion {
    /// True for `<8 digits>-<6…64 lowercase hex digits>`.
    public static func isValid(_ version: String) -> Bool {
        let parts = version.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        let hash = parts[1]
        return (6...64).contains(hash.count) && hash.allSatisfy(\.isLowercaseHexDigit)
    }

    /// The `yyyymmdd` the lists were built on; nil for a version of another shape.
    public static func buildDate(_ version: String) -> String? {
        isValid(version) ? String(version.prefix(8)) : nil
    }

    /// Whether `candidate` may replace `current` in the engine. The same rule decides at engine
    /// startup between the bundled ruleset and the downloaded one (`AdBlocker::LoadBundledRuleset`
    /// in the Chromium patch): a ruleset built on the same day or later replaces the other, an
    /// older one never does, so an app update that bundles newer lists wins over an older
    /// download. Equal versions are no change. A `current` of unknown shape (or none) is
    /// replaced.
    public static func mayReplace(current: String?, with candidate: String) -> Bool {
        guard let newDate = buildDate(candidate) else { return false }
        guard let current else { return true }
        if current == candidate { return false }
        guard let currentDate = buildDate(current) else { return true }
        return newDate >= currentDate
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isLowercaseHexDigit: Bool { isASCIIDigit || ("a"..."f").contains(self) }
}

// MARK: - Trust

/// The public keys a manifest signature must verify against (Ed25519, raw 32-byte keys).
public struct AdBlockRulesetTrust: Sendable {
    /// Base64 of Open Arc's ruleset signing key (generated 2026-10-27; the private key never
    /// enters the repository, see scripts/publish-adblock-ruleset.sh). To rotate, add the new key
    /// here, ship a release, then sign with the new key and drop the old one in a later release.
    public static let openArcPublicKeys = ["u1vCypbfSLbUYy4UQyrKU7dJk/9sOl6/CDlCeTa8d08="]

    /// Open Arc's own keys.
    public static let openArc = AdBlockRulesetTrust(base64Keys: openArcPublicKeys)!

    public let publicKeys: [Curve25519.Signing.PublicKey]

    public init(publicKeys: [Curve25519.Signing.PublicKey]) {
        self.publicKeys = publicKeys
    }

    /// nil when a key is not base64 of 32 bytes.
    public init?(base64Keys: [String]) {
        var keys: [Curve25519.Signing.PublicKey] = []
        for text in base64Keys {
            guard let raw = Data(base64Encoded: text),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
            keys.append(key)
        }
        self.init(publicKeys: keys)
    }

    /// Verifies `signatureFile` (base64 of the 64-byte signature, surrounding whitespace allowed)
    /// over `manifestData`, then decodes and checks the manifest. Nothing in the manifest is read
    /// before the signature holds.
    public func verifiedManifest(_ manifestData: Data, signatureFile: Data) throws -> AdBlockRulesetManifest {
        let text = String(decoding: signatureFile, as: UTF8.self).filter { !$0.isWhitespace }
        guard let signature = Data(base64Encoded: text), signature.count == 64 else {
            throw AdBlockRulesetUpdateError.badSignature
        }
        guard publicKeys.contains(where: { $0.isValidSignature(signature, for: manifestData) }) else {
            throw AdBlockRulesetUpdateError.badSignature
        }
        let manifest: AdBlockRulesetManifest
        do {
            manifest = try JSONDecoder().decode(AdBlockRulesetManifest.self, from: manifestData)
        } catch {
            throw AdBlockRulesetUpdateError.malformedManifest(String(describing: error))
        }
        guard manifest.type == AdBlockRulesetManifest.typeIdentifier,
              manifest.format == AdBlockRulesetManifest.currentFormat else {
            throw AdBlockRulesetUpdateError.unsupportedManifest
        }
        guard AdBlockRulesetVersion.isValid(manifest.version) else {
            throw AdBlockRulesetUpdateError.invalidVersion(manifest.version)
        }
        for file in [manifest.ruleset, manifest.attribution] {
            guard Self.isSafeRelativePath(file.path) else { throw AdBlockRulesetUpdateError.invalidPath(file.path) }
            guard file.size >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy(\.isLowercaseHexDigit) else {
                throw AdBlockRulesetUpdateError.malformedManifest("bad size or sha256 for \(file.path)")
            }
        }
        return manifest
    }

    /// A path below the manifest's directory: no scheme, no leading "/", no "." / ".." segment,
    /// no query, fragment or backslash.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.contains(where: { ":?#\\%".contains($0) || $0.isWhitespace }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

// MARK: - Configuration

/// Where the updater looks, and when.
public enum AdBlockRulesetUpdateConfiguration {
    /// The manifest on our static host: GitHub Pages next to the Sparkle appcast (docs/release.md
    /// §Choose the static host). A placeholder like the appcast's `SUFeedURL` until the host
    /// exists; while it is, updates stay off (no request goes to a domain we do not own).
    public static let placeholderManifestURL = "https://openarc.github.io/adblock/manifest.json"
    /// True until the static host is set up; flip it together with the URL above.
    public static let isHostPlaceholder = true
    /// Environment override, for the local test host (chromium-bridge/README.md §Ad blocking):
    /// `OPENARC_ADBLOCK_MANIFEST_URL=http://127.0.0.1:8765/adblock/manifest.json`. The signature
    /// is still checked against the built-in key.
    public static let manifestURLEnvironmentKey = "OPENARC_ADBLOCK_MANIFEST_URL"

    /// Largest manifest, signature and ruleset accepted (the merged lists are about 4 MB).
    public static let maxManifestBytes = 64 * 1024
    public static let maxRulesetBytes = 64 * 1024 * 1024

    /// First check after the engine started, then the period between checks.
    public static let initialDelay: Duration = .seconds(30)
    public static let checkInterval: Duration = .seconds(24 * 60 * 60)

    /// The manifest URL in effect: the override when set (http or https), else the built-in URL
    /// unless it is still the placeholder. nil keeps the updater off.
    public static func manifestURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment[manifestURLEnvironmentKey], !override.isEmpty {
            guard let url = URL(string: override), ["http", "https"].contains(url.scheme?.lowercased()) else {
                return nil
            }
            return url
        }
        return isHostPlaceholder ? nil : URL(string: placeholderManifestURL)
    }
}

// MARK: - Fetching

/// Reads a URL into memory with a size limit.
public protocol AdBlockRulesetFetching: Sendable {
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data
}

/// `URLSession` without cookies or cache. HTTP status must be 200.
public struct URLSessionRulesetFetcher: AdBlockRulesetFetching {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw AdBlockRulesetUpdateError.download("\(url.absoluteString): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AdBlockRulesetUpdateError.download("\(url.absoluteString): HTTP \(http.statusCode)")
        }
        guard data.count <= maxBytes else {
            throw AdBlockRulesetUpdateError.sizeMismatch("\(url.lastPathComponent) is larger than \(maxBytes) bytes")
        }
        return data
    }
}

// MARK: - Store

/// The downloaded rulesets, `<engine user data dir>/Open Arc Ad Block/`:
///
/// ```
/// rulesets/<version>/ruleset.pb, ruleset.version, ATTRIBUTION   one directory per version
/// Current -> rulesets/<version>                                   the one the engine loads at startup
/// state.json                                                      {"serial": …, "version": …}
/// ```
///
/// A version directory is written under a temporary name and renamed into place, and `Current` is
/// swapped by renaming a new symbolic link over it, so a crash at any point leaves either the old
/// or the new ruleset complete. The Chromium patch reads `Current` at startup (`AdBlocker`'s
/// `kDownloadedRulesetDirectory`); keep the names in sync.
public struct AdBlockRulesetStore: Sendable {
    public static let directoryName = "Open Arc Ad Block"
    public static let currentLinkName = "Current"

    struct State: Codable, Equatable {
        var serial: Int64
        var version: String
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The store inside Chromium's user data directory.
    public init(userDataDirectory: URL) {
        self.init(root: userDataDirectory.appendingPathComponent(Self.directoryName, isDirectory: true))
    }

    var rulesetsDirectory: URL { root.appendingPathComponent("rulesets", isDirectory: true) }
    var currentLink: URL { root.appendingPathComponent(Self.currentLinkName) }
    var stateFile: URL { root.appendingPathComponent("state.json") }

    /// The highest serial accepted so far (0 for a new store).
    public var lastSerial: Int64 { state?.serial ?? 0 }

    var state: State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// The version directory `Current` points to, resolved; nil when there is none.
    public var currentDirectory: URL? {
        let fileManager = FileManager.default
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path) else { return nil }
        // Appended, not resolved relative to `root`: a root URL without a trailing slash (a store
        // that did not exist yet when the URL was made) would lose its last component.
        let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : root.appendingPathComponent(target))
            .standardizedFileURL
        return fileManager.fileExists(atPath: resolved.appendingPathComponent("ruleset.pb").path) ? resolved : nil
    }

    /// Writes a verified ruleset as `rulesets/<version>/`, points `Current` at it, records the
    /// serial and removes versions other than the new and the previous one (the engine may still
    /// be indexing the previous one). Returns the new version directory.
    @discardableResult
    public func install(_ manifest: AdBlockRulesetManifest, ruleset: Data, attribution: Data) throws -> URL {
        let fileManager = FileManager.default
        let version = manifest.version
        let previous = currentDirectory
        let destination = rulesetsDirectory.appendingPathComponent(version, isDirectory: true)
        do {
            try fileManager.createDirectory(at: rulesetsDirectory, withIntermediateDirectories: true)
            let staging = rulesetsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                try ruleset.write(to: staging.appendingPathComponent("ruleset.pb"))
                try attribution.write(to: staging.appendingPathComponent("ATTRIBUTION"))
                // The version file last: the engine treats a directory without it as no ruleset.
                try Data((version + "\n").utf8).write(to: staging.appendingPathComponent("ruleset.version"))
                if fileManager.fileExists(atPath: destination.path) {
                    // Same version published again (a retry after a crash): replace it whole.
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }

            // rename(2) of a fresh link over `Current` is atomic; the link target is relative so the
            // store survives a moved data directory.
            let newLink = root.appendingPathComponent(".\(Self.currentLinkName)-\(UUID().uuidString)")
            try fileManager.createSymbolicLink(atPath: newLink.path, withDestinationPath: "rulesets/\(version)")
            guard rename(newLink.path, currentLink.path) == 0 else {
                let code = errno
                try? fileManager.removeItem(at: newLink)
                throw AdBlockRulesetUpdateError.store("swap Current: \(String(cString: strerror(code)))")
            }

            let stateData = try JSONEncoder().encode(State(serial: manifest.serial, version: version))
            try stateData.write(to: stateFile, options: .atomic)
        } catch let error as AdBlockRulesetUpdateError {
            throw error
        } catch {
            throw AdBlockRulesetUpdateError.store(error.localizedDescription)
        }
        prune(keeping: [destination, previous].compactMap { $0?.standardizedFileURL.lastPathComponent })
        return destination
    }

    private func prune(keeping names: [String]) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: rulesetsDirectory.path) else { return }
        for name in entries where !names.contains(name) {
            try? fileManager.removeItem(at: rulesetsDirectory.appendingPathComponent(name))
        }
    }
}

// MARK: - Updater

/// What one check did.
public enum AdBlockRulesetUpdateOutcome: Equatable, Sendable {
    /// The host offers nothing newer than `activeVersion`.
    case upToDate
    /// A verified ruleset was stored; hand `directory` to the engine.
    case installed(version: String, directory: URL)
    /// The check failed or the host's data was rejected; nothing changed on disk.
    case failed(AdBlockRulesetUpdateError)
}

/// One update check: manifest → verify → compare → download → verify → store.
public struct AdBlockRulesetUpdater: Sendable {
    public let manifestURL: URL
    public let trust: AdBlockRulesetTrust
    public let store: AdBlockRulesetStore
    public let fetcher: any AdBlockRulesetFetching

    public init(
        manifestURL: URL, trust: AdBlockRulesetTrust = .openArc, store: AdBlockRulesetStore,
        fetcher: any AdBlockRulesetFetching = URLSessionRulesetFetcher()
    ) {
        self.manifestURL = manifestURL
        self.trust = trust
        self.store = store
        self.fetcher = fetcher
    }

    /// `activeVersion`: the ruleset the engine uses now (nil: none).
    public func check(activeVersion: String?) async -> AdBlockRulesetUpdateOutcome {
        do {
            let limit = AdBlockRulesetUpdateConfiguration.maxManifestBytes
            let manifestData = try await fetcher.fetch(manifestURL, maxBytes: limit)
            let signatureURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(manifestURL.lastPathComponent + ".sig")
            let signature = try await fetcher.fetch(signatureURL, maxBytes: limit)
            let manifest = try trust.verifiedManifest(manifestData, signatureFile: signature)

            guard AdBlockRulesetVersion.mayReplace(current: activeVersion, with: manifest.version) else {
                return .upToDate
            }
            // Checked after the version: the manifest already installed (same serial, engine now on
            // that version) is "up to date", not a replay.
            guard manifest.serial > store.lastSerial else {
                throw AdBlockRulesetUpdateError.replayedSerial(manifest.serial)
            }

            let ruleset = try await download(manifest.ruleset, maxBytes: AdBlockRulesetUpdateConfiguration.maxRulesetBytes)
            let attribution = try await download(manifest.attribution, maxBytes: limit)
            let directory = try store.install(manifest, ruleset: ruleset, attribution: attribution)
            return .installed(version: manifest.version, directory: directory)
        } catch let error as AdBlockRulesetUpdateError {
            return .failed(error)
        } catch {
            return .failed(.download(error.localizedDescription))
        }
    }

    private func download(_ file: AdBlockRulesetManifest.File, maxBytes: Int) async throws -> Data {
        guard file.size <= maxBytes else {
            throw AdBlockRulesetUpdateError.sizeMismatch("\(file.path): \(file.size) bytes is over the limit")
        }
        guard let url = URL(string: file.path, relativeTo: manifestURL)?.absoluteURL else {
            throw AdBlockRulesetUpdateError.invalidPath(file.path)
        }
        let data = try await fetcher.fetch(url, maxBytes: maxBytes)
        guard data.count == file.size else {
            throw AdBlockRulesetUpdateError.sizeMismatch("\(file.path): \(data.count) bytes, manifest says \(file.size)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw AdBlockRulesetUpdateError.hashMismatch(file.path) }
        return data
    }
}
