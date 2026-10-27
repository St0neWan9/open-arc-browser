import XCTest
import CommonCrypto
import SQLite3
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// D3b: history and password import in the real engine, run from `testChromiumEngineConformance`
/// (Chromium starts once per process). The sources are made up here: a fake Chrome profile folder
/// (a `History` database and a `Login Data` database whose passwords are encrypted the way Chrome
/// encrypts them, with Chromium's mock keychain password since the test runs with
/// `--use-mock-keychain` and the keychain item does not exist), a passwords CSV and a Safari
/// history JSON. No real browser data is read. [01 §Arc] observed the menu item; what the import
/// brings over is inferred ([00] import wizard not captured).
extension ChromiumEngineConformanceTests {
    @MainActor
    func checkImport(_ engine: ChromiumEngine, profileID: UUID) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openarc-d3b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        let now = Date()
        try ImportFixtures.writeHistory(at: chrome.appendingPathComponent("History"), rows: [
            ("https://one.example.com/", "One", now.addingTimeInterval(-3_600)),
            ("https://two.example.com/a", "Two", now.addingTimeInterval(-86_400)),
            ("https://old.example.com/", "Old", now.addingTimeInterval(-200 * 86_400)),   // beyond 90 days
            ("chrome://settings/", "Settings", now),                                     // not http(s)
        ])
        try ImportFixtures.writeLogins(at: chrome.appendingPathComponent("Login Data"), rows: [
            ("https://login.example.com/", "alice", "s3cret-A"),
            ("https://other.example.com/signin", "bob", "s3cret-B"),
        ], keyPassword: "mock_password")

        let source = EngineImportSource.chromiumProfile(
            directory: chrome, keychainService: "Open Arc Test Import Safe Storage", keychainAccount: "Open Arc Test Import"
        )
        let first = await engine.importer.importData([.history, .passwords], from: source, into: profileID)
        XCTAssertEqual(first.historyStatus, .success)
        XCTAssertEqual(first.historyCount, 2, "only recent http(s) pages")
        XCTAssertEqual(first.passwordStatus, .success)
        XCTAssertEqual(first.passwordCount, 2)
        XCTAssertEqual(first.passwordConflicts, 0)

        // Importing again: identical logins count as already saved, nothing conflicts.
        let again = await engine.importer.importData(.passwords, from: source, into: profileID)
        XCTAssertEqual(again.passwordStatus, .success)
        XCTAssertEqual(again.passwordConflicts, 0)

        // A CSV with another password for alice keeps the saved one (a conflict) and adds carol.
        let csv = root.appendingPathComponent("Passwords.csv")
        try Data("""
        Title,URL,Username,Password,Notes,OTPAuth
        Login,https://login.example.com/,alice,changed,,
        Third,https://third.example.com/,carol,s3cret-C,,

        """.utf8).write(to: csv)
        let fromCSV = await engine.importer.importData(.passwords, from: .exportFile(csv), into: profileID)
        XCTAssertEqual(fromCSV.passwordStatus, .success)
        XCTAssertEqual(fromCSV.passwordConflicts, 1)
        XCTAssertEqual(fromCSV.passwordCount, 1)

        // Safari's history JSON export.
        let json = root.appendingPathComponent("History.json")
        let usec = Int64(now.addingTimeInterval(-600).timeIntervalSince1970 * 1_000_000)
        try Data("""
        {"metadata":{"browser_name":"Safari","browser_version":"18.0","data_type":"history","export_time_usec":\(usec),"schema_version":1},
         "history":[{"url":"https://safari.example.com/","title":"Safari Page","time_usec":\(usec),"visit_count":3}]}
        """.utf8).write(to: json)
        let fromJSON = await engine.importer.importData(.history, from: .exportFile(json), into: profileID)
        XCTAssertEqual(fromJSON.historyStatus, .success)
        XCTAssertEqual(fromJSON.historyCount, 1)

        // A Safari library folder without History.db, and a missing profile folder.
        let emptySafari = await engine.importer.importData(.history, from: .safari(libraryDirectory: root), into: profileID)
        XCTAssertEqual(emptySafari.historyStatus, .notFound)
        let missing = await engine.importer.importData(
            [.history, .passwords],
            from: .chromiumProfile(directory: root.appendingPathComponent("nope"), keychainService: "x", keychainAccount: "x"),
            into: profileID
        )
        XCTAssertEqual(missing.historyStatus, .notFound)
        XCTAssertEqual(missing.passwordStatus, .notFound)

        // The imported pages are in the profile's history: chrome://history lists them.
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID))
        defer { Task { await engine.closeTab(tab.id) } }
        try await tab.load(try XCTUnwrap(URL(string: "chrome://history/?q=example.com")))
        try await waitForState(tab) { $0.title == "History" && !$0.loadState.isLoading }
    }
}

/// Writes the made-up source databases of `checkImport`.
enum ImportFixtures {
    /// Chrome's `urls` table (times in microseconds since 1601-01-01).
    static func writeHistory(at url: URL, rows: [(String, String, Date)]) throws {
        try withDatabase(url) { db in
            try exec(db, "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL)")
            for (address, title, date) in rows {
                let time = Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
                try exec(db, "INSERT INTO urls(url,title,visit_count,typed_count,last_visit_time,hidden) VALUES('\(address)','\(title)',2,1,\(time),0)")
            }
        }
    }

    /// Chrome's `logins` table with "v10" passwords: AES-128-CBC, IV of 16 spaces, key
    /// PBKDF2-HMAC-SHA1(keyPassword, "saltysalt", 1003).
    static func writeLogins(at url: URL, rows: [(String, String, String)], keyPassword: String) throws {
        let key = deriveKey(keyPassword)
        try withDatabase(url) { db in
            try exec(db, "CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR, password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL)")
            for (origin, user, password) in rows {
                let blob = Data("v10".utf8) + encrypt(Data(password.utf8), key: key)
                let realm = URL(string: origin).map { "\($0.scheme!)://\($0.host!)/" } ?? origin
                try exec(db, "INSERT INTO logins VALUES('\(origin)','','u','\(user)','p',X'\(blob.map { String(format: "%02X", $0) }.joined())','','\(realm)',0,0,0)")
            }
        }
    }

    private static func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private static func deriveKey(_ password: String) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        key.withUnsafeMutableBytes { out in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                out.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128
            )
        }
        return key
    }

    private static func encrypt(_ plain: Data, key: Data) -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let outCount = out.count
        out.withUnsafeMutableBytes { outBytes in
            plain.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    _ = CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, inBytes.baseAddress, plain.count,
                        outBytes.baseAddress, outCount, &written
                    )
                }
            }
        }
        return out.prefix(written)
    }
}
