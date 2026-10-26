import XCTest
import OpenArcModel
import OpenArcSyncAPI

/// The shared `RecordMerge` (OpenArcSyncAPI/RecordMerge.swift), used by both the local store and
/// the CloudKit backend. It applies `ConflictPolicy`: field-group last-writer-wins, delete wins,
/// ties go to the server. Delete-wins follows from archiving being a delete
/// (docs/arc-spec/05-surfaces.md, ⌘W archives, observed); the rest is our own design (inferred).
final class RecordMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func theme() -> Theme {
        Theme(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, colors: [RGBAColor(hex: 0x112233)], now: t0)
    }

    /// Every field of the `style` group, brightness included, travels with the group.
    func testThemeStyleGroupIncludingBrightnessMergesAsOneUnit() throws {
        var local = theme()
        local.brightness = 0.9
        local.grain = 0.4
        local.meta.stamp([Theme.FieldGroup.style], at: t(20))
        var server = theme()
        server.colors = [RGBAColor(hex: 0xFFEEDD)]
        server.meta.stamp([Theme.FieldGroup.style], at: t(10))

        let outcome = try XCTUnwrap(RecordMerge.merge(local: .theme(local), server: .theme(server)))
        guard case .theme(let merged) = outcome.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.style, local.style, "the later group wins whole; no mix of both sides")
        XCTAssertTrue(outcome.needsUpload)
        XCTAssertFalse(outcome.isDeleted)

        let reversed = try XCTUnwrap(RecordMerge.merge(local: .theme(server), server: .theme(local)))
        guard case .theme(let merged2) = reversed.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged2.style, local.style)
        XCTAssertFalse(reversed.needsUpload)
    }

    /// `Profile.settings` merges as its own group: a rename on one device and a settings change on
    /// another both survive. [03 §Profiles] observed (settings are per profile).
    func testProfileSettingsAndNameMergeIndependently() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var local = Profile(id: id, name: "Personal", now: t0)
        local.settings = ProfileSettings(searchEngine: .bing, todayLifetime: 3600)
        local.meta.stamp([Profile.FieldGroup.settings], at: t(20))
        var server = Profile(id: id, name: "Personal", now: t0)
        server.name = "Home"
        server.meta.stamp([Profile.FieldGroup.naming], at: t(10))

        let outcome = try XCTUnwrap(RecordMerge.merge(local: .profile(local), server: .profile(server)))
        guard case .profile(let merged) = outcome.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.name, "Home")
        XCTAssertEqual(merged.settings, local.settings)
        XCTAssertTrue(outcome.needsUpload)
    }

    /// Merging a record with itself is a no-op (`SyncLocalDatabase.apply` must be idempotent).
    func testIdenticalCopiesMergeToTheLocalCopy() throws {
        let record = SyncRecord.theme(theme())
        let outcome = try XCTUnwrap(RecordMerge.merge(local: record, server: record))
        XCTAssertEqual(outcome.merged, record)
        XCTAssertFalse(outcome.needsUpload)
        XCTAssertFalse(outcome.isDeleted)
    }

    /// Delete wins; a local delete the server has not seen yet must be uploaded.
    func testLocalDeleteWinsAndNeedsUpload() throws {
        var local = theme()
        local.meta.markDeleted(at: t(5))
        var server = theme()
        server.brightness = 0.1
        server.meta.stamp([Theme.FieldGroup.style], at: t(50))
        let outcome = try XCTUnwrap(RecordMerge.merge(local: .theme(local), server: .theme(server)))
        XCTAssertTrue(outcome.isDeleted)
        XCTAssertTrue(outcome.merged.meta.isTombstone)
        XCTAssertTrue(outcome.needsUpload)
    }

    /// A20: the outcome reports which groups the local copy won; a merge the server wins entirely
    /// is the server copy as it is (version included), so applying it is not a local change.
    func testOutcomeReportsLocalWinsAndKeepsServerVersionWhenServerWinsAll() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var local = Profile(id: id, name: "Personal", now: t0)
        local.name = "Old"
        local.meta.stamp([Profile.FieldGroup.naming], at: t(10))
        var server = Profile(id: id, name: "Personal", now: t0)
        server.name = "New"
        server.meta.stamp([Profile.FieldGroup.naming], at: t(20))
        server.meta.version = 9

        let remoteWins = try XCTUnwrap(RecordMerge.merge(local: .profile(local), server: .profile(server)))
        XCTAssertEqual(remoteWins.merged, .profile(server))
        XCTAssertTrue(remoteWins.localWonGroups.isEmpty)
        XCTAssertTrue(remoteWins.serverWinsAll)
        XCTAssertFalse(remoteWins.needsUpload)

        local.settings = ProfileSettings(searchEngine: .bing, todayLifetime: 60)
        local.meta.stamp([Profile.FieldGroup.settings], at: t(30))
        let mixed = try XCTUnwrap(RecordMerge.merge(local: .profile(local), server: .profile(server)))
        XCTAssertEqual(mixed.localWonGroups, ["settings"])
        XCTAssertTrue(mixed.needsUpload)
        XCTAssertEqual(mixed.merged.meta.version, max(local.meta.version, 9) + 1)
        guard case .profile(let merged) = mixed.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.name, "New")
        XCTAssertEqual(merged.settings, local.settings)
    }

    /// Different records never merge.
    func testDifferentRecordsReturnNil() {
        let other = Theme(id: UUID(), colors: [], now: t0)
        XCTAssertNil(RecordMerge.merge(local: .theme(theme()), server: .theme(other)))
        let profile = Profile(id: theme().id, name: "P", now: t0)
        XCTAssertNil(RecordMerge.merge(local: .theme(theme()), server: .profile(profile)))
    }
}
