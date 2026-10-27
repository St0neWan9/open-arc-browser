import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// Plan D4: `scripts/cloudkit/schema.ckdb` is the CloudKit schema imported into Development and
/// deployed to Production. Production cannot create record types or fields on the fly, so every
/// record type and field that `RecordMapper` writes must be declared there, with the same CloudKit
/// type and the same encrypted/plain choice. These tests fail when the code and the file drift.
final class CloudKitSchemaFileTests: XCTestCase {

    /// One declared field: its CloudKit type as written in the file, e.g. "ENCRYPTED STRING".
    private struct DeclaredField: Equatable {
        let type: String
        let options: Set<String>
    }

    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // OpenArcSyncCloudKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // app
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("scripts/cloudkit/schema.ckdb")

    /// CloudKit system record type, declared so an import never tries to drop it.
    private static let systemRecordTypes: Set<String> = ["Users"]

    // MARK: - Tests

    func testEveryRecordTypeIsDeclared() throws {
        let schema = try Self.parseSchema()
        let declared = Set(schema.keys).subtracting(Self.systemRecordTypes)
        let written = Set(SyncRecordType.allCases.map(\.rawValue))
        XCTAssertEqual(declared.subtracting(written), [], "schema.ckdb declares record types the code never writes")
        XCTAssertEqual(written.subtracting(declared), [], "record types missing from schema.ckdb (plan D4)")
    }

    /// Every field key in `RecordSchema` is declared, no undeclared extras, and the encrypted flag
    /// matches (`encryptedValues` fields must be ENCRYPTED in CloudKit).
    func testEveryFieldIsDeclaredWithMatchingEncryption() throws {
        let schema = try Self.parseSchema()
        for type in SyncRecordType.allCases {
            let fields = schema[type.rawValue] ?? [:]
            let specs = RecordSchema.fields(of: type)
            let declaredKeys = Set(fields.keys.filter { !$0.hasPrefix("___") })
            let codeKeys = Set(specs.map(\.key))
            XCTAssertEqual(codeKeys.subtracting(declaredKeys), [], "\(type.rawValue): fields missing from schema.ckdb")
            XCTAssertEqual(declaredKeys.subtracting(codeKeys), [], "\(type.rawValue): schema.ckdb fields the code never writes")
            for spec in specs {
                guard let declared = fields[spec.key] else { continue }
                XCTAssertEqual(declared.type.contains("ENCRYPTED"), spec.encrypted,
                               "\(type.rawValue).\(spec.key): encrypted flag differs from RecordSchema")
            }
        }
    }

    /// The declared CloudKit type matches the value `RecordMapper` actually stores. Every field
    /// must be filled by at least one fixture, so a new field without a fixture value fails here.
    func testDeclaredTypesMatchTheValuesTheMapperWrites() throws {
        let schema = try Self.parseSchema()
        var seen: [SyncRecordType: [String: String]] = [:]
        let records = (Fx.fullRecords(variant: 0) + Fx.fullRecords(variant: 1)).map { record in
            record.mapMeta { meta in
                meta.isTombstone = true
                meta.deletedAt = Fx.t(5)
                for group in RecordSchema.groups(of: record.id.type) { meta.fieldGroupModifiedAt[group] = Fx.t(1) }
            }
        }
        for record in records {
            let ck = Fx.mapper.makeCKRecord(record, systemFields: nil)
            for spec in RecordSchema.fields(of: record.id.type) {
                let value: Any? = spec.encrypted ? ck.encryptedValues[spec.key] : ck.object(forKey: spec.key)
                guard let value else { continue }
                let base = try XCTUnwrap(Self.cloudKitType(of: value), "\(record.id.type.rawValue).\(spec.key): unmapped value type")
                seen[record.id.type, default: [:]][spec.key] = spec.encrypted ? Self.encrypted(base) : base
            }
        }
        for type in SyncRecordType.allCases {
            for spec in RecordSchema.fields(of: type) {
                let label = "\(type.rawValue).\(spec.key)"
                guard let actual = seen[type]?[spec.key] else {
                    XCTFail("\(label): no fixture writes a value; extend Fx so the type check covers it")
                    continue
                }
                XCTAssertEqual(schema[type.rawValue]?[spec.key]?.type, actual, "\(label): schema.ckdb type differs from the written value")
            }
        }
    }

    /// The Console can list records only with a queryable record id; nothing else needs an index
    /// because CKSyncEngine fetches by zone change token.
    func testRecordIDIsQueryableAndNoOtherIndexes() throws {
        let schema = try Self.parseSchema()
        for type in SyncRecordType.allCases {
            let fields = schema[type.rawValue] ?? [:]
            XCTAssertEqual(fields["___recordID"], DeclaredField(type: "REFERENCE", options: ["QUERYABLE"]), type.rawValue)
            for (key, field) in fields where key != "___recordID" {
                XCTAssertEqual(field.options, [], "\(type.rawValue).\(key): unexpected index")
            }
        }
    }

    // MARK: - Helpers

    private static func encrypted(_ base: String) -> String {
        base.hasPrefix("LIST<") ? "LIST<ENCRYPTED \(base.dropFirst(5))" : "ENCRYPTED \(base)"
    }

    /// CloudKit schema type of a stored value. NSNumber is told apart by its ObjC type: RecordMapper
    /// stores Swift `Double` (encoding "d") or `Int64` (encoding "q").
    private static func cloudKitType(of value: Any) -> String? {
        switch value {
        case is String, is NSString: return "STRING"
        case is Date, is NSDate: return "TIMESTAMP"
        case is Data, is NSData: return "BYTES"
        case is [String]: return "LIST<STRING>"
        case let number as NSNumber:
            switch String(cString: number.objCType) {
            case "d", "f": return "DOUBLE"
            case "q", "l", "i", "s", "c": return "INT64"
            default: return nil
            }
        default: return nil
        }
    }

    /// Minimal parser for the `.ckdb` subset we use: `RECORD TYPE <name> ( field TYPE [OPTIONS], … );`.
    /// Comments (`//`, `--`, `/* */`) and GRANT entries are skipped.
    private static func parseSchema() throws -> [String: [String: DeclaredField]] {
        var text = try String(contentsOf: schemaURL, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = Substring(line)
            for marker in ["//", "--"] {
                if let range = line.range(of: marker) { line = line[..<range.lowerBound] }
            }
            return String(line)
        }.joined(separator: "\n")

        let regex = try NSRegularExpression(pattern: #"RECORD\s+TYPE\s+"?(\w+)"?\s*\(([\s\S]*?)\)\s*;"#)
        let ns = text as NSString
        var result: [String: [String: DeclaredField]] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            var fields: [String: DeclaredField] = [:]
            for entry in ns.substring(with: match.range(at: 2)).split(separator: ",") {
                let tokens = entry.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = tokens.first, first.uppercased() != "GRANT" else { continue }
                let key = first.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let optionWords: Set<String> = ["QUERYABLE", "SORTABLE", "SEARCHABLE"]
                let rest = tokens.dropFirst()
                let type = rest.filter { !optionWords.contains($0.uppercased()) }.joined(separator: " ").uppercased()
                let options = Set(rest.map { $0.uppercased() }.filter(optionWords.contains))
                XCTAssertNil(fields[key], "\(name).\(key) declared twice")
                fields[key] = DeclaredField(type: type, options: options)
            }
            XCTAssertNil(result[name], "record type \(name) declared twice")
            result[name] = fields
        }
        XCTAssertFalse(result.isEmpty, "no record types parsed from \(schemaURL.path)")
        return result
    }
}
