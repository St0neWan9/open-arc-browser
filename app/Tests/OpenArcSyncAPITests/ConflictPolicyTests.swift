import XCTest
import OpenArcModel
import OpenArcSyncAPI

final class ConflictPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func baseTab() throws -> (WorkspaceState, UUID) {
        let profile = UUID(), space = UUID(), tab = UUID()
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "S", now: t0)
        s = try TreeOps.openTab(s, id: tab, spaceID: space, url: nil, title: "T", now: t0)
        s = try TreeOps.pinTab(s, id: tab, now: t0)
        return (s, tab)
    }

    /// Device A renames, device B navigates the same tab: both edits survive.
    func testDifferentGroupsBothSurvive() throws {
        let (base, tab) = try baseTab()
        let local = try TreeOps.renameTab(base, id: tab, customTitle: "Mine", now: t(10))
        let server = try TreeOps.updateTabContent(base, id: tab, url: URL(string: "https://new.example"), title: "New", faviconURL: nil, now: t(20))

        let r = ConflictPolicy.resolve(local: try XCTUnwrap(local.tabs[tab]).meta, server: try XCTUnwrap(server.tabs[tab]).meta, groups: TabNode.FieldGroup.self)
        XCTAssertFalse(r.isDeleted)
        XCTAssertEqual(r.winners[.naming], .local)
        XCTAssertEqual(r.winners[.content], .server)
        XCTAssertTrue(r.needsUpload)
        XCTAssertEqual(r.mergedMeta.modifiedAt(TabNode.FieldGroup.naming), t(10))
        XCTAssertEqual(r.mergedMeta.modifiedAt(TabNode.FieldGroup.content), t(20))
    }

    func testSameGroupLaterWriteWins() throws {
        let (base, tab) = try baseTab()
        let local = try TreeOps.renameTab(base, id: tab, customTitle: "Later", now: t(30))
        let server = try TreeOps.renameTab(base, id: tab, customTitle: "Earlier", now: t(20))
        let r = ConflictPolicy.resolve(local: try XCTUnwrap(local.tabs[tab]).meta, server: try XCTUnwrap(server.tabs[tab]).meta, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(r.winners[.naming], .local)
    }

    func testTieGoesToServer() throws {
        let (base, tab) = try baseTab()
        let local = try TreeOps.renameTab(base, id: tab, customTitle: "L", now: t(5))
        let server = try TreeOps.renameTab(base, id: tab, customTitle: "S", now: t(5))
        let r = ConflictPolicy.resolve(local: try XCTUnwrap(local.tabs[tab]).meta, server: try XCTUnwrap(server.tabs[tab]).meta, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(r.winners[.naming], .server)
        XCTAssertFalse(r.needsUpload)
    }

    func testDeleteWinsOverLaterEdit() throws {
        let (base, tab) = try baseTab()
        let local = try TreeOps.archiveTab(base, id: tab, now: t(1))
        let server = try TreeOps.renameTab(base, id: tab, customTitle: "Edited later", now: t(100))
        let r = ConflictPolicy.resolve(local: try XCTUnwrap(local.tabs[tab]).meta, server: try XCTUnwrap(server.tabs[tab]).meta, groups: TabNode.FieldGroup.self)
        XCTAssertTrue(r.isDeleted)
        XCTAssertTrue(r.mergedMeta.isTombstone)
        XCTAssertEqual(r.mergedMeta.deletedAt, t(1))
        XCTAssertTrue(r.localWonGroups.isEmpty)
        XCTAssertTrue(r.needsUpload, "the server has not seen the local delete yet")

        // Symmetric: a server-side delete also wins over a later local edit.
        let r2 = ConflictPolicy.resolve(local: try XCTUnwrap(server.tabs[tab]).meta, server: try XCTUnwrap(local.tabs[tab]).meta, groups: TabNode.FieldGroup.self)
        XCTAssertTrue(r2.isDeleted)
        XCTAssertFalse(r2.needsUpload, "the server already has the delete")
    }

    func testMergedMetadataKeepsServerSystemFields() throws {
        let (base, tab) = try baseTab()
        var localMeta = try XCTUnwrap(base.tabs[tab]).meta
        var serverMeta = localMeta
        localMeta.backendSystemFields = Data([1])
        serverMeta.backendSystemFields = Data([2])
        let r = ConflictPolicy.resolve(local: localMeta, server: serverMeta, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(r.mergedMeta.backendSystemFields, Data([2]))
        XCTAssertEqual(r.mergedMeta, serverMeta, "the server wins everything: its metadata as it is")

        localMeta.stamp([TabNode.FieldGroup.naming], at: t(50))
        let mixed = ConflictPolicy.resolve(local: localMeta, server: serverMeta, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(mixed.mergedMeta.backendSystemFields, Data([2]))
        XCTAssertGreaterThan(mixed.mergedMeta.version, max(localMeta.version, serverMeta.version))
    }

    /// A20: `version` only advances when the local side contributes something to upload. A merge
    /// the server wins entirely keeps the server's version, so it never looks like a local change.
    func testVersionAdvancesOnlyWhenLocalWinsSomething() throws {
        let (base, tab) = try baseTab()
        let local = try XCTUnwrap(try TreeOps.renameTab(base, id: tab, customTitle: "Old", now: t(10)).tabs[tab]).meta
        var server = try XCTUnwrap(try TreeOps.renameTab(base, id: tab, customTitle: "New", now: t(20)).tabs[tab]).meta
        server.version = 3

        let serverWins = ConflictPolicy.resolve(local: local, server: server, groups: TabNode.FieldGroup.self)
        XCTAssertTrue(serverWins.localWonGroups.isEmpty)
        XCTAssertFalse(serverWins.needsUpload)
        XCTAssertEqual(serverWins.mergedMeta, server)
        XCTAssertEqual(serverWins.mergedMeta.version, 3)

        let localWins = ConflictPolicy.resolve(local: server, server: local, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(localWins.localWonGroups, [.naming])
        XCTAssertTrue(localWins.needsUpload)
        XCTAssertEqual(localWins.mergedMeta.version, 4)

        // A server delete wins as the server wrote it; a local delete the server lacks is uploaded.
        var deleted = server
        deleted.markDeleted(at: t(30))
        let serverDelete = ConflictPolicy.resolve(local: local, server: deleted, groups: TabNode.FieldGroup.self)
        XCTAssertEqual(serverDelete.mergedMeta, deleted)
        XCTAssertFalse(serverDelete.needsUpload)
        let localDelete = ConflictPolicy.resolve(local: deleted, server: local, groups: TabNode.FieldGroup.self)
        XCTAssertTrue(localDelete.isDeleted)
        XCTAssertTrue(localDelete.localDeleteNotOnServer)
        XCTAssertTrue(localDelete.needsUpload)
        XCTAssertTrue(localDelete.localWonGroups.isEmpty)
        XCTAssertGreaterThan(localDelete.mergedMeta.version, deleted.version)
    }
}

final class SyncRecordTests: XCTestCase {
    func testRecordNamesAreStableAndTypeQualified() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF"))
        XCTAssertEqual(SyncRecordID(type: .tab, uuid: uuid).recordName, "Tab/6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        // An archive item shares its tab's UUID but is a different record.
        XCTAssertNotEqual(SyncRecordID(type: .tab, uuid: uuid), SyncRecordID(type: .archiveItem, uuid: uuid))
    }

    func testRecordTypeNamesMatchModel() {
        XCTAssertEqual(SyncRecordType.profile.rawValue, Profile.recordTypeName)
        XCTAssertEqual(SyncRecordType.theme.rawValue, Theme.recordTypeName)
        XCTAssertEqual(SyncRecordType.space.rawValue, Space.recordTypeName)
        XCTAssertEqual(SyncRecordType.folder.rawValue, Folder.recordTypeName)
        XCTAssertEqual(SyncRecordType.tab.rawValue, TabNode.recordTypeName)
        XCTAssertEqual(SyncRecordType.archiveItem.rawValue, ArchiveItem.recordTypeName)
        XCTAssertEqual(SyncRecordType.splitLayout.rawValue, SplitLayout.recordTypeName)
    }

    /// Every encrypted group name must be a real field group of that record type.
    func testEncryptedGroupsExistInModel() {
        func names<G: SyncFieldGroup>(_: G.Type) -> Set<String> { Set(G.allCases.map(\.rawValue)) }
        let groups: [SyncRecordType: Set<String>] = [
            .profile: names(Profile.FieldGroup.self),
            .theme: names(Theme.FieldGroup.self),
            .space: names(Space.FieldGroup.self),
            .folder: names(Folder.FieldGroup.self),
            .tab: names(TabNode.FieldGroup.self),
            .archiveItem: names(ArchiveItem.FieldGroup.self),
            .splitLayout: names(SplitLayout.FieldGroup.self),
        ]
        for type in SyncRecordType.allCases {
            XCTAssertTrue(type.encryptedFieldGroups.isSubset(of: groups[type] ?? []), "\(type)")
        }
    }

    func testSyncRecordCodableAndIdentity() throws {
        let now = Date(timeIntervalSince1970: 0)
        let tab = TabNode(id: UUID(), location: .today(spaceID: UUID()), sortKey: .initial, url: nil, title: "T", now: now)
        let record = SyncRecord.tab(tab)
        XCTAssertEqual(record.id, SyncRecordID(type: .tab, uuid: tab.id))
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testDisabledStoreReportsDisabled() async {
        let store = DisabledSyncStore()
        let status = await store.currentStatus()
        XCTAssertEqual(status, .disabled)
        var updates: [SyncStatus] = []
        for await s in store.statusUpdates() { updates.append(s) }
        XCTAssertEqual(updates, [.disabled])
    }
}
