import XCTest
import CryptoKit
@testable import OpenArcEngine

/// Plan B234: the phishing list file, matching, and the signed update through the ad-block updater.
final class PhishingListB234Tests: XCTestCase {
    func testFileRoundTripAndMatching() throws {
        let data = PhishingList.file(hosts: ["login-paypa1.example", "www.bank-verify.test", "LOGIN-PAYPA1.example.", ""])
        let list = try XCTUnwrap(PhishingList(data: data))
        XCTAssertEqual(list.count, 2, "normalized and deduplicated")
        XCTAssertTrue(list.contains(URL(string: "https://login-paypa1.example/signin")!))
        XCTAssertTrue(list.contains(URL(string: "http://LOGIN-PAYPA1.EXAMPLE")!))
        XCTAssertTrue(list.contains(URL(string: "https://www.login-paypa1.example/")!), "www. of a listed host")
        XCTAssertTrue(list.contains(URL(string: "https://bank-verify.test/")!), "listed with www.")
        XCTAssertFalse(list.contains(URL(string: "https://sub.login-paypa1.example/")!), "exact hosts only")
        XCTAssertFalse(list.contains(URL(string: "https://example.com/")!))
        XCTAssertFalse(list.contains(URL(string: "file:///login-paypa1.example")!))
    }

    func testRejectsMalformedFiles() {
        var data = PhishingList.file(hosts: ["a.test", "b.test"])
        XCTAssertNil(PhishingList(data: data.dropLast()), "truncated")
        data[3] = 0x58
        XCTAssertNil(PhishingList(data: data), "bad magic")
        XCTAssertNil(PhishingList(data: Data()))
    }

    /// The updater takes a phishing manifest and refuses an ad-block one for the phishing list.
    func testSignedUpdateUsesItsOwnManifestType() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let trust = AdBlockRulesetTrust(publicKeys: [key.publicKey])
        let list = PhishingList.file(hosts: ["evil.test"])
        let attribution = Data("Phishing.Database (MIT)".utf8)
        func manifest(type: String) throws -> Data {
            let m = AdBlockRulesetManifest(
                type: type, format: 1, serial: 7, version: "20261116-abcdef",
                ruleset: .init(path: "lists/20261116-abcdef/list.bin", size: list.count, sha256: hex(SHA256.hash(data: list))),
                attribution: .init(path: "lists/20261116-abcdef/ATTRIBUTION", size: attribution.count, sha256: hex(SHA256.hash(data: attribution))))
            return try JSONEncoder().encode(m)
        }
        let base = URL(string: "https://host.test/phishing/manifest.json")!
        for (type, expectInstalled) in [(PhishingList.typeIdentifier, true), (AdBlockRulesetManifest.typeIdentifier, false)] {
            let body = try manifest(type: type)
            let signature = Data(try key.signature(for: body).base64EncodedString().utf8)
            let fetcher = MapFetcher(files: [
                base: body,
                URL(string: "https://host.test/phishing/manifest.json.sig")!: signature,
                URL(string: "https://host.test/phishing/lists/20261116-abcdef/list.bin")!: list,
                URL(string: "https://host.test/phishing/lists/20261116-abcdef/ATTRIBUTION")!: attribution,
            ])
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("phish-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let updater = AdBlockRulesetUpdater(manifestURL: base, trust: trust, store: AdBlockRulesetStore(root: root),
                                                fetcher: fetcher, manifestType: PhishingList.typeIdentifier,
                                                maxListBytes: PhishingList.maxListBytes)
            let outcome = await updater.check(activeVersion: nil)
            if expectInstalled {
                guard case .installed(_, let directory) = outcome else { return XCTFail("\(outcome)") }
                let stored = try Data(contentsOf: directory.appendingPathComponent(PhishingList.listFileName))
                XCTAssertTrue(try XCTUnwrap(PhishingList(data: stored)).contains(URL(string: "https://evil.test/")!))
            } else {
                XCTAssertEqual(outcome, .failed(.unsupportedManifest))
            }
        }
    }

    private func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

private struct MapFetcher: AdBlockRulesetFetching {
    let files: [URL: Data]
    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        guard let data = files[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}
