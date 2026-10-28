import CryptoKit
import XCTest
@testable import OpenArcEngine

/// Plan C19: ad-block filter-list updates from our static host. The spec only records that the
/// project hosts the merged filter rules as static content ([00 §已定的服务策略] observed) and that
/// the ad blocker is an engine feature with a settings switch ([00 §A 内核继承] "广告拦截"
/// observed); the manifest, signature and store are our design.
final class AdBlockRulesetUpdateTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openarc-adblock-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Fixtures

    private let manifestURL = URL(string: "http://127.0.0.1:8765/adblock/manifest.json")!
    private let ruleset = Data("ruleset bytes v2".utf8)
    private let attribution = Data("attribution".utf8)

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(
        version: String = "20261028-0123456789ab", serial: Int64 = 2, rulesetPath: String? = nil,
        rulesetHash: String? = nil
    ) -> AdBlockRulesetManifest {
        AdBlockRulesetManifest(
            serial: serial, version: version, published: "2026-10-28T00:00:00Z",
            ruleset: .init(path: rulesetPath ?? "rulesets/\(version)/ruleset.pb", size: ruleset.count,
                           sha256: rulesetHash ?? hex(ruleset)),
            attribution: .init(path: "rulesets/\(version)/ATTRIBUTION", size: attribution.count, sha256: hex(attribution))
        )
    }

    private func signed(_ manifest: AdBlockRulesetManifest, with key: Curve25519.Signing.PrivateKey) throws -> (Data, Data) {
        let data = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: data)
        return (data, Data((signature.base64EncodedString() + "\n").utf8))
    }

    private struct StubFetcher: AdBlockRulesetFetching {
        var files: [String: Data]
        func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
            guard let data = files[url.absoluteString] else { throw AdBlockRulesetUpdateError.download("404 \(url)") }
            guard data.count <= maxBytes else { throw AdBlockRulesetUpdateError.sizeMismatch(url.lastPathComponent) }
            return data
        }
    }

    /// A host serving `manifest` signed by `key`, with `rulesetBody` at the ruleset's path.
    private func updater(
        _ manifest: AdBlockRulesetManifest, signedBy key: Curve25519.Signing.PrivateKey,
        trusting trusted: Curve25519.Signing.PrivateKey? = nil, rulesetBody: Data? = nil
    ) throws -> AdBlockRulesetUpdater {
        let (data, signature) = try signed(manifest, with: key)
        let base = "http://127.0.0.1:8765/adblock/"
        let fetcher = StubFetcher(files: [
            base + "manifest.json": data,
            base + "manifest.json.sig": signature,
            base + manifest.ruleset.path: rulesetBody ?? ruleset,
            base + manifest.attribution.path: attribution,
        ])
        return AdBlockRulesetUpdater(
            manifestURL: manifestURL, trust: AdBlockRulesetTrust(publicKeys: [(trusted ?? key).publicKey]),
            store: AdBlockRulesetStore(root: root), fetcher: fetcher
        )
    }

    // MARK: Signature and manifest

    /// Interop with scripts/publish-adblock-ruleset.sh: a manifest it signed with the real private
    /// key (outside the repo) verifies against the public key built into the app.
    func testManifestFromPublishScriptVerifiesWithBuiltInKey() throws {
        let manifest = Data(base64Encoded: "ewogICJ0eXBlIjogIm9yZy5vcGVuYXJjLmFkYmxvY2stcnVsZXNldCIsCiAgImZvcm1hdCI6IDEsCiAgInNlcmlhbCI6IDcsCiAgInZlcnNpb24iOiAiMjAyNjEwMjctYWJjZGVmMDEyMzQ1IiwKICAicHVibGlzaGVkIjogIjIwMjYtMTAtMjdUMTU6NDQ6MThaIiwKICAicnVsZXNldCI6IHsKICAgICJwYXRoIjogInJ1bGVzZXRzLzIwMjYxMDI3LWFiY2RlZjAxMjM0NS9ydWxlc2V0LnBiIiwKICAgICJzaXplIjogMjIsCiAgICAic2hhMjU2IjogImYyMTFmZGIzODBiNzgwMTE3MTczN2FlZWI1YzEzMDY5Nzg5NGI1NzBkOTgzMDhjNDk2MDU3NzMwNWUyZjkyOTAiCiAgfSwKICAiYXR0cmlidXRpb24iOiB7CiAgICAicGF0aCI6ICJydWxlc2V0cy8yMDI2MTAyNy1hYmNkZWYwMTIzNDUvQVRUUklCVVRJT04iLAogICAgInNpemUiOiAyMCwKICAgICJzaGEyNTYiOiAiZjViMTc3MWE2NTgzNmFiYTAyZjU2Mjk3ZmYxYTZlZTUzZjQyM2EyZTMxOWU3ZWNjOWVlY2FjYWYyZTNiNTcwNSIKICB9Cn0K")!
        let signature = Data("k71YUng1NR9toIQkv0IbRksjQoCbh5tJ4MmT8AO7uOIcL/WR1wUvQ26Bf8wKlH9WexCzzOQITkMw0aXOqcctDA==\n".utf8)

        let verified = try AdBlockRulesetTrust.openArc.verifiedManifest(manifest, signatureFile: signature)
        XCTAssertEqual(verified.version, "20261027-abcdef012345")
        XCTAssertEqual(verified.serial, 7)
        XCTAssertEqual(verified.ruleset.size, 22)
        XCTAssertEqual(verified.attribution.path, "rulesets/20261027-abcdef012345/ATTRIBUTION")

        // One changed byte (serial 7 -> 8) breaks it.
        var tampered = manifest
        let index = try XCTUnwrap(tampered.firstIndex(of: UInt8(ascii: "7")))
        tampered[index] = UInt8(ascii: "8")
        XCTAssertThrowsError(try AdBlockRulesetTrust.openArc.verifiedManifest(tampered, signatureFile: signature)) {
            XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .badSignature)
        }
    }

    func testBuiltInKeyParses() {
        XCTAssertEqual(AdBlockRulesetTrust.openArc.publicKeys.count, AdBlockRulesetTrust.openArcPublicKeys.count)
        XCTAssertNil(AdBlockRulesetTrust(base64Keys: ["not base64"]))
        XCTAssertNil(AdBlockRulesetTrust(base64Keys: [Data(count: 31).base64EncodedString()]))
    }

    func testSignatureFromAnotherKeyIsRejected() throws {
        let (data, signature) = try signed(manifest(), with: .init())
        let trust = AdBlockRulesetTrust(publicKeys: [Curve25519.Signing.PrivateKey().publicKey])
        XCTAssertThrowsError(try trust.verifiedManifest(data, signatureFile: signature)) {
            XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .badSignature)
        }
    }

    func testMalformedSignatureFileIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (data, _) = try signed(manifest(), with: key)
        let trust = AdBlockRulesetTrust(publicKeys: [key.publicKey])
        for file in ["", "@@@", Data(count: 63).base64EncodedString()] {
            XCTAssertThrowsError(try trust.verifiedManifest(data, signatureFile: Data(file.utf8))) {
                XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .badSignature)
            }
        }
    }

    func testAnyTrustedKeyVerifies() throws {
        let old = Curve25519.Signing.PrivateKey(), new = Curve25519.Signing.PrivateKey()
        let (data, signature) = try signed(manifest(), with: new)
        let trust = AdBlockRulesetTrust(publicKeys: [old.publicKey, new.publicKey])
        XCTAssertEqual(try trust.verifiedManifest(data, signatureFile: signature).serial, 2)
    }

    func testSignedButUnsupportedOrUnsafeManifestsAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = AdBlockRulesetTrust(publicKeys: [key.publicKey])
        func verify(_ manifest: AdBlockRulesetManifest) throws {
            let (data, signature) = try signed(manifest, with: key)
            _ = try trust.verifiedManifest(data, signatureFile: signature)
        }
        var other = manifest()
        other.type = "org.example.something-else"
        XCTAssertThrowsError(try verify(other)) { XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .unsupportedManifest) }
        var future = manifest()
        future.format = 2
        XCTAssertThrowsError(try verify(future)) { XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .unsupportedManifest) }
        XCTAssertThrowsError(try verify(manifest(version: "../../x"))) {
            XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .invalidVersion("../../x"))
        }
        for path in ["/etc/passwd", "../ruleset.pb", "rulesets/../../x", "https://evil.example/r.pb", "a//b", "a/./b"] {
            XCTAssertThrowsError(try verify(manifest(rulesetPath: path))) {
                XCTAssertEqual($0 as? AdBlockRulesetUpdateError, .invalidPath(path))
            }
        }
        XCTAssertThrowsError(try verify(manifest(rulesetHash: "ABC"))) {
            guard case .malformedManifest = $0 as? AdBlockRulesetUpdateError else { return XCTFail("\($0)") }
        }
    }

    func testSignedGarbageIsMalformed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("{\"type\":1}".utf8)
        let signature = Data(try key.signature(for: data).base64EncodedString().utf8)
        XCTAssertThrowsError(try AdBlockRulesetTrust(publicKeys: [key.publicKey]).verifiedManifest(data, signatureFile: signature)) {
            guard case .malformedManifest = $0 as? AdBlockRulesetUpdateError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Versions

    func testVersionShapeAndReplacementRule() {
        XCTAssertTrue(AdBlockRulesetVersion.isValid("20261027-e7d406ab505d"))
        XCTAssertFalse(AdBlockRulesetVersion.isValid("20261027-E7D406"))
        XCTAssertFalse(AdBlockRulesetVersion.isValid("2026102-e7d406ab505d"))
        XCTAssertFalse(AdBlockRulesetVersion.isValid("20261027-e7d40"))
        XCTAssertFalse(AdBlockRulesetVersion.isValid("fake-ruleset"))

        XCTAssertTrue(AdBlockRulesetVersion.mayReplace(current: nil, with: "20261027-aaaaaa"))
        XCTAssertTrue(AdBlockRulesetVersion.mayReplace(current: "20261027-aaaaaa", with: "20261028-bbbbbb"))
        XCTAssertTrue(AdBlockRulesetVersion.mayReplace(current: "20261027-aaaaaa", with: "20261027-bbbbbb"))
        XCTAssertFalse(AdBlockRulesetVersion.mayReplace(current: "20261027-aaaaaa", with: "20261027-aaaaaa"))
        XCTAssertFalse(AdBlockRulesetVersion.mayReplace(current: "20261028-aaaaaa", with: "20261027-bbbbbb"))
        XCTAssertTrue(AdBlockRulesetVersion.mayReplace(current: "fake-ruleset", with: "20261027-bbbbbb"))
        XCTAssertFalse(AdBlockRulesetVersion.mayReplace(current: nil, with: "bogus"))
    }

    // MARK: Configuration

    /// D14: the built-in manifest URL is the public repository's `updates` branch (https).
    func testManifestURLPointsAtTheHostedFeed() {
        XCTAssertFalse(AdBlockRulesetUpdateConfiguration.isHostPlaceholder)
        XCTAssertEqual(AdBlockRulesetUpdateConfiguration.manifestURL(environment: [:]),
                       URL(string: "https://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/adblock/manifest.json"))
        XCTAssertEqual(
            AdBlockRulesetUpdateConfiguration.manifestURL(environment: ["OPENARC_ADBLOCK_MANIFEST_URL": "http://127.0.0.1:8765/adblock/manifest.json"]),
            manifestURL
        )
        XCTAssertNil(AdBlockRulesetUpdateConfiguration.manifestURL(environment: ["OPENARC_ADBLOCK_MANIFEST_URL": "file:///tmp/manifest.json"]))
    }

    // MARK: Updater and store

    func testNewerRulesetIsFetchedVerifiedAndSwappedIn() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let outcome = try await updater(manifest(), signedBy: key).check(activeVersion: "20261027-e7d406ab505d")

        let store = AdBlockRulesetStore(root: root)
        guard case .installed(let version, let directory) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(version, "20261028-0123456789ab")
        XCTAssertEqual(store.currentDirectory?.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("ruleset.pb")), ruleset)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("ATTRIBUTION")), attribution)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("ruleset.version"), encoding: .utf8), version + "\n")
        XCTAssertEqual(store.lastSerial, 2)
        // `Current` is a relative link, so the store survives a moved data directory.
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Current").path)
        XCTAssertEqual(link, "rulesets/\(version)")
    }

    func testBadSignatureLeavesTheStoreUntouched() async throws {
        let outcome = try await updater(manifest(), signedBy: .init(), trusting: .init()).check(activeVersion: nil)
        XCTAssertEqual(outcome, .failed(.badSignature))
        XCTAssertNil(AdBlockRulesetStore(root: root).currentDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rulesets").path))
    }

    func testTamperedRulesetIsRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        var body = ruleset
        body[0] ^= 1
        let outcome = try await updater(manifest(), signedBy: key, rulesetBody: body).check(activeVersion: nil)
        XCTAssertEqual(outcome, .failed(.hashMismatch("rulesets/20261028-0123456789ab/ruleset.pb")))
        XCTAssertNil(AdBlockRulesetStore(root: root).currentDirectory)

        let short = try await updater(manifest(), signedBy: key, rulesetBody: ruleset.dropLast()).check(activeVersion: nil)
        guard case .failed(.sizeMismatch) = short else { return XCTFail("\(short)") }
    }

    func testSameOrOlderVersionIsUpToDate() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let same = try await updater(manifest(), signedBy: key).check(activeVersion: "20261028-0123456789ab")
        XCTAssertEqual(same, .upToDate)
        let older = try await updater(manifest(), signedBy: key).check(activeVersion: "20261101-ffffff")
        XCTAssertEqual(older, .upToDate)
    }

    func testReplayedSerialIsRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        guard case .installed = try await updater(manifest(serial: 5), signedBy: key).check(activeVersion: nil) else {
            return XCTFail("first install")
        }
        // A genuinely signed but older manifest with a different version comes back.
        let replay = try await updater(manifest(version: "20261029-0123456789ab", serial: 4), signedBy: key)
            .check(activeVersion: "20261028-0123456789ab")
        XCTAssertEqual(replay, .failed(.replayedSerial(4)))
        XCTAssertEqual(AdBlockRulesetStore(root: root).currentDirectory?.lastPathComponent, "20261028-0123456789ab")
    }

    func testStoreKeepsOnlyTheNewAndThePreviousVersion() throws {
        // A root URL made before the directory exists has no trailing slash (the app's case).
        let store = AdBlockRulesetStore(root: URL(fileURLWithPath: root.path))
        XCTAssertFalse(store.root.hasDirectoryPath)
        for (serial, version) in [(1, "20261026-aaaaaa"), (2, "20261027-bbbbbb"), (3, "20261028-cccccc")] {
            try store.install(manifest(version: version, serial: Int64(serial)), ruleset: ruleset, attribution: attribution)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rulesets").path).sorted()
        XCTAssertEqual(kept, ["20261027-bbbbbb", "20261028-cccccc"])
        XCTAssertEqual(store.currentDirectory?.lastPathComponent, "20261028-cccccc")
        XCTAssertEqual(store.lastSerial, 3)
        // No temporary links or staging directories are left behind.
        let top = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(top, ["Current", "rulesets", "state.json"])
    }

    func testOversizedRulesetIsRefusedBeforeDownload() async throws {
        let key = Curve25519.Signing.PrivateKey()
        var big = manifest()
        big.ruleset.size = AdBlockRulesetUpdateConfiguration.maxRulesetBytes + 1
        let outcome = try await updater(big, signedBy: key).check(activeVersion: nil)
        guard case .failed(.sizeMismatch) = outcome else { return XCTFail("\(outcome)") }
    }

    // MARK: Engine contract

    func testFakeEngineReportsLiveVersionChanges() async {
        let blocker = FakeAdBlocking(rulesetVersion: "20261027-aaaaaa")
        var changes = blocker.rulesetVersionChanges().makeAsyncIterator()
        blocker.simulateRuleset("20261027-aaaaaa") // unchanged: not delivered
        blocker.simulateRuleset("20261028-bbbbbb")
        let next = await changes.next()
        XCTAssertEqual(next, "20261028-bbbbbb")
        let current = await blocker.rulesetVersion()
        XCTAssertEqual(current, "20261028-bbbbbb")
    }

    func testEnginesWithoutUpdatesEndTheStream() async {
        var changes = UnavailableAdBlocking.shared.rulesetVersionChanges().makeAsyncIterator()
        let next = await changes.next()
        XCTAssertNil(next)
    }
}
