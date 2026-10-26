import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// The shared `RecordMerge` (OpenArcSyncAPI/RecordMerge.swift), as the CloudKit store uses it.
/// It applies `ConflictPolicy` (OpenArcSyncAPI/ConflictPolicy.swift): field-group
/// last-writer-wins, delete wins, ties go to the server.
final class FieldGroupMergeTests: XCTestCase {

    /// Base tab both devices start from.
    private func base() -> TabNode { Fx.tab() }

    private func merge(_ local: TabNode, _ server: TabNode, file: StaticString = #filePath, line: UInt = #line) throws -> (TabNode, RecordMerge.Outcome) {
        let outcome = try XCTUnwrap(RecordMerge.merge(local: .tab(local), server: .tab(server)), file: file, line: line)
        let merged = try XCTUnwrap(outcome.merged.tab, file: file, line: line)
        return (merged, outcome)
    }

    // MARK: Per-group last writer wins

    func testLaterGroupTimestampWinsPerGroup() throws {
        var local = base()
        local.customTitle = "Local name"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(20))
        var server = base()
        server.customTitle = "Server name"
        server.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(10))

        let (merged, outcome) = try merge(local, server)
        XCTAssertEqual(merged.customTitle, "Local name")
        XCTAssertEqual(merged.meta.fieldGroupModifiedAt["naming"], Fx.t(20))
        XCTAssertTrue(outcome.needsUpload, "local won a group, server must learn it")
        XCTAssertFalse(outcome.isDeleted)

        // Reversed timestamps: the server wins and nothing needs uploading.
        local.meta.fieldGroupModifiedAt["naming"] = Fx.t(5)
        let (merged2, outcome2) = try merge(local, server)
        XCTAssertEqual(merged2.customTitle, "Server name")
        XCTAssertFalse(outcome2.needsUpload)
    }

    func testUnrelatedGroupsFromBothSidesSurvive() throws {
        // Local renames, server navigates and goes active: both edits must remain.
        var local = base()
        local.customTitle = "Renamed"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(10))
        var server = base()
        server.url = URL(string: "https://navigated.example")
        server.title = "Navigated"
        server.faviconURL = nil
        server.lastActiveAt = Fx.t(15)
        server.meta.stamp([TabNode.FieldGroup.content, .activity], at: Fx.t(15))

        let (merged, outcome) = try merge(local, server)
        XCTAssertEqual(merged.customTitle, "Renamed")
        XCTAssertEqual(merged.url, URL(string: "https://navigated.example"))
        XCTAssertEqual(merged.title, "Navigated")
        XCTAssertNil(merged.faviconURL)
        XCTAssertEqual(merged.lastActiveAt, Fx.t(15))
        XCTAssertEqual(merged.location, base().location, "untouched group keeps its value")
        XCTAssertEqual(merged.meta.fieldGroupModifiedAt["naming"], Fx.t(10))
        XCTAssertEqual(merged.meta.fieldGroupModifiedAt["content"], Fx.t(15))
        XCTAssertEqual(merged.meta.modifiedAt, Fx.t(15))
        XCTAssertTrue(outcome.needsUpload)
    }

    func testTieGoesToServer() throws {
        var local = base()
        local.customTitle = "Local"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(10))
        var server = base()
        server.customTitle = "Server"
        server.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(10))

        let (merged, outcome) = try merge(local, server)
        XCTAssertEqual(merged.customTitle, "Server")
        XCTAssertFalse(outcome.needsUpload)

        // Identical copies merge to the server copy with nothing to upload.
        let (same, sameOutcome) = try merge(base(), base())
        XCTAssertEqual(same.customTitle, base().customTitle)
        XCTAssertFalse(sameOutcome.needsUpload)
    }

    /// A move rewrites location + sort key together (`placement` group); a merge never combines
    /// the location of one side with the sort key of the other.
    func testMoveIsNeverSplit() throws {
        var local = base()
        local.location = .today(spaceID: Fx.uuid(3))
        local.sortKey = Fx.key("a")
        local.meta.stamp([TabNode.FieldGroup.placement], at: Fx.t(20))
        var server = base()
        server.location = .pinned(spaceID: Fx.uuid(3), folderID: Fx.uuid(77))
        server.sortKey = Fx.key("z")
        server.meta.stamp([TabNode.FieldGroup.placement], at: Fx.t(10))

        let (localWins, _) = try merge(local, server)
        XCTAssertEqual(localWins.location, .today(spaceID: Fx.uuid(3)))
        XCTAssertEqual(localWins.sortKey, Fx.key("a"))

        local.meta.fieldGroupModifiedAt["placement"] = Fx.t(5)
        let (serverWins, _) = try merge(local, server)
        XCTAssertEqual(serverWins.location, .pinned(spaceID: Fx.uuid(3), folderID: Fx.uuid(77)))
        XCTAssertEqual(serverWins.sortKey, Fx.key("z"))
    }

    func testFolderMoveIsNeverSplit() throws {
        var local = Fx.folder()
        local.spaceID = Fx.uuid(200)
        local.parentFolderID = nil
        local.sortKey = Fx.key("b")
        local.meta.stamp([Folder.FieldGroup.placement], at: Fx.t(30))
        var server = Fx.folder()
        server.title = "Server title"
        server.meta.stamp([Folder.FieldGroup.naming], at: Fx.t(40))

        let outcome = try XCTUnwrap(RecordMerge.merge(local: .folder(local), server: .folder(server)))
        guard case .folder(let merged) = outcome.merged else { return XCTFail("wrong type") }
        XCTAssertEqual(merged.spaceID, Fx.uuid(200))
        XCTAssertNil(merged.parentFolderID)
        XCTAssertEqual(merged.sortKey, Fx.key("b"))
        XCTAssertEqual(merged.title, "Server title")
        XCTAssertTrue(outcome.needsUpload)
    }

    // MARK: Delete wins

    func testServerDeleteWinsOverNewerLocalEdit() throws {
        var local = base()
        local.customTitle = "Edited after delete"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(100))
        var server = base()
        server.meta.markDeleted(at: Fx.t(10))

        let (merged, outcome) = try merge(local, server)
        XCTAssertTrue(outcome.isDeleted)
        XCTAssertTrue(merged.meta.isTombstone)
        XCTAssertEqual(merged.meta.deletedAt, Fx.t(10))
        XCTAssertEqual(merged.customTitle, base().customTitle, "tombstone keeps server values")
        XCTAssertFalse(outcome.needsUpload, "the server already has the delete")
    }

    func testLocalDeleteWinsAndIsUploaded() throws {
        var local = base()
        local.meta.markDeleted(at: Fx.t(10))
        var server = base()
        server.customTitle = "Newer server edit"
        server.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(100))

        let (merged, outcome) = try merge(local, server)
        XCTAssertTrue(outcome.isDeleted)
        XCTAssertTrue(merged.meta.isTombstone)
        XCTAssertTrue(outcome.needsUpload, "server has not seen the local delete yet")
    }

    func testBothDeletedKeepsEarliestDeleteAndNeedsNoUpload() throws {
        var local = base()
        local.meta.markDeleted(at: Fx.t(20))
        var server = base()
        server.meta.markDeleted(at: Fx.t(10))
        let (merged, outcome) = try merge(local, server)
        XCTAssertTrue(outcome.isDeleted)
        XCTAssertEqual(merged.meta.deletedAt, Fx.t(10))
        XCTAssertFalse(outcome.needsUpload)
    }

    // MARK: Metadata and identity

    func testMergedRecordCarriesServerSystemFields() throws {
        var local = base()
        local.meta.backendSystemFields = Data("local".utf8)
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(20))
        var server = base()
        server.meta.backendSystemFields = Data("server".utf8)
        let (merged, _) = try merge(local, server)
        XCTAssertEqual(merged.meta.backendSystemFields, Data("server".utf8))
    }

    func testDifferentRecordsDoNotMerge() {
        XCTAssertNil(RecordMerge.merge(local: .tab(Fx.tab(Fx.uuid(1))), server: .tab(Fx.tab(Fx.uuid(2)))))
        // Same UUID, different type (an ArchiveItem shares its tab's UUID).
        XCTAssertNil(RecordMerge.merge(local: .tab(Fx.tab(Fx.uuid(9))), server: .archiveItem(Fx.archiveItem(Fx.uuid(9)))))
    }

    /// Every type: a local win in every group copies every field; a server win keeps server values.
    /// Guards the per-type copy functions against a forgotten field.
    func testEveryTypeCopiesAllFieldsOfWinningGroups() throws {
        let locals = Fx.fullRecords(variant: 1)
        let servers = Fx.fullRecords(variant: 0)
        for (local, server) in zip(locals, servers) {
            let type = local.id.type
            let newer = local.mapMeta { meta in
                for group in RecordSchema.groups(of: type) { meta.fieldGroupModifiedAt[group] = Fx.t(50) }
            }
            let localWins = try XCTUnwrap(RecordMerge.merge(local: newer, server: server), "\(type)")
            XCTAssertEqual(localWins.merged.mapMeta { $0 = newer.meta }, newer, "\(type): local must win every group")
            XCTAssertTrue(localWins.needsUpload)

            let serverWins = try XCTUnwrap(RecordMerge.merge(local: local, server: server), "\(type)")
            XCTAssertEqual(serverWins.merged.mapMeta { $0 = server.meta }, server, "\(type): tie must keep server values")
            XCTAssertFalse(serverWins.needsUpload)
        }
    }
}
