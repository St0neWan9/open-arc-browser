import XCTest
import OpenArcModel
import OpenArcSyncAPI

/// Conflict policy coverage for Easel records (B56; canvas from docs/arc-spec/06-flows.md §9,
/// observed). Field-group last-writer-wins, delete wins, ties to the server are our own design.
final class EaselMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let easelID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    private let elementID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!

    private func element() -> EaselElement {
        EaselElement(
            id: elementID, easelID: easelID, zKey: .initial, frame: EaselRect(x: 0, y: 0, width: 10, height: 10),
            content: .text(string: "Hello"),
            style: EaselStyle(strokeColor: RGBAColor(hex: 0x111111), strokeWidth: 3, fontSize: 18), now: t0
        )
    }

    /// [06 §9] One device moves a text box while another edits its text: both edits survive.
    func testMoveAndTextEditOnTwoDevicesBothSurvive() throws {
        var local = element()
        local.frame = EaselRect(x: 50, y: 60, width: 10, height: 10)
        local.meta.stamp([EaselElement.FieldGroup.geometry], at: t(20))
        var server = element()
        server.content = .text(string: "Hello, world")
        server.meta.stamp([EaselElement.FieldGroup.content], at: t(10))

        let outcome = try XCTUnwrap(RecordMerge.merge(local: .easelElement(local), server: .easelElement(server)))
        guard case .easelElement(let merged) = outcome.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.frame, local.frame)
        XCTAssertEqual(merged.content, server.content)
        XCTAssertEqual(merged.style, server.style)
        XCTAssertEqual(outcome.localWonGroups, [EaselElement.FieldGroup.geometry.rawValue])
        XCTAssertTrue(outcome.needsUpload)
    }

    /// A deleted element stays deleted even when the other device edited it later.
    func testDeleteWinsOverLaterEdit() throws {
        var local = element()
        local.meta.markDeleted(at: t(5))
        var server = element()
        server.frame = EaselRect(x: 1, y: 1, width: 1, height: 1)
        server.meta.stamp([EaselElement.FieldGroup.geometry], at: t(30))
        let outcome = try XCTUnwrap(RecordMerge.merge(local: .easelElement(local), server: .easelElement(server)))
        XCTAssertTrue(outcome.isDeleted)
        XCTAssertTrue(outcome.needsUpload)
    }

    /// Two renames at the same instant: the server's title wins on every device.
    func testTitleTieGoesToServer() throws {
        var local = Easel(id: easelID, now: t0)
        local.title = "Mine"
        local.meta.stamp([Easel.FieldGroup.naming], at: t(10))
        var server = Easel(id: easelID, now: t0)
        server.title = "Theirs"
        server.meta.stamp([Easel.FieldGroup.naming], at: t(10))
        let outcome = try XCTUnwrap(RecordMerge.merge(local: .easel(local), server: .easel(server)))
        guard case .easel(let merged) = outcome.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.title, "Theirs")
        XCTAssertFalse(outcome.needsUpload)
    }

    func testEaselRecordIDsAndEncryption() {
        XCTAssertEqual(SyncRecord.easel(Easel(id: easelID, now: t0)).id.recordName, "Easel/\(easelID.uuidString)")
        XCTAssertEqual(SyncRecord.easelElement(element()).id.recordName, "EaselElement/\(elementID.uuidString)")
        XCTAssertEqual(SyncRecordType.easel.encryptedFieldGroups, ["naming"])
        XCTAssertEqual(SyncRecordType.easelElement.encryptedFieldGroups, ["content", "geometry", "style"])
    }
}
