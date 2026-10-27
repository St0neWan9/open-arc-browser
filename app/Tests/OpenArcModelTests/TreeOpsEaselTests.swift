import XCTest
@testable import OpenArcModel

/// Easel records and their tree operations. Spec: docs/arc-spec/06-flows.md §9 (canvas, "Untitled
/// Easel" title), §4 (an Easel is a pinned row with an Easel icon), §8 / §11 (Library ▸ Easels; an
/// Easel outlives its Space). Gestures and stacking are inferred (B56).
final class TreeOpsEaselTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let profile = UUID(), home = UUID(), work = UUID()
    private let easel = UUID(), row = UUID(), e1 = UUID(), e2 = UUID(), e3 = UUID()
    private let style = EaselStyle(strokeColor: RGBAColor(hex: 0x111111), strokeWidth: 3, fontSize: 18)

    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: t0)
        s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", now: t0)
        s = try TreeOps.openTab(s, id: UUID(), spaceID: home, url: URL(string: "https://a.example"), title: "A", now: t0)
        return s
    }

    private func withEasel() throws -> WorkspaceState {
        try TreeOps.createEasel(try base(), id: easel, tabID: row, spaceID: home, now: at(1))
    }

    private func rect(_ x: Double) -> EaselRect { EaselRect(x: x, y: x, width: 10, height: 10) }

    // MARK: Create, pinned row [06 §9, §4]

    /// [06 §9] observed: a new Easel is "Untitled Easel". [06 §4] observed: it appears as a row in
    /// the pinned area; its URL is the Easel link.
    func testCreateEaselMakesUntitledEaselWithPinnedRow() throws {
        let s = try withEasel()
        XCTAssertEqual(s.easels[easel]?.title, "Untitled Easel")
        let tab = try XCTUnwrap(s.tabs[row])
        XCTAssertEqual(tab.location, .pinned(spaceID: home, folderID: nil))
        XCTAssertEqual(tab.url, EaselLink.url(for: easel))
        XCTAssertEqual(tab.title, "Untitled Easel")
        XCTAssertEqual(s.easelID(ofTab: row), easel)
        XCTAssertEqual(s.pinnedChildren(spaceID: home, folderID: nil).map(\.id), [row])
        XCTAssertEqual(s.liveEaselsNewestFirst.map(\.id), [easel])
    }

    func testEaselLinkRoundTripsAndRejectsOtherURLs() throws {
        let id = UUID()
        XCTAssertEqual(EaselLink.url(for: id).absoluteString, "openarc://easel/\(id.uuidString)")
        XCTAssertEqual(EaselLink.easelID(from: EaselLink.url(for: id)), id)
        XCTAssertNil(EaselLink.easelID(from: URL(string: "https://easel/\(id.uuidString)")))
        XCTAssertNil(EaselLink.easelID(from: URL(string: "openarc://other/\(id.uuidString)")))
        XCTAssertNil(EaselLink.easelID(from: URL(string: "openarc://easel/not-a-uuid")))
        XCTAssertNil(EaselLink.easelID(from: nil))
    }

    // MARK: Rename [06 §9]

    /// [06 §9] observed: the title is editable. Only `naming` of the Easel and `content` of its
    /// rows are stamped.
    func testRenameStampsNamingAndUpdatesRows() throws {
        var s = try withEasel()
        s = try TreeOps.renameTab(s, id: row, customTitle: "Old row name", now: at(2))
        let before = s
        s = try TreeOps.renameEasel(s, id: easel, title: "  Moodboard ", now: at(5))
        XCTAssertEqual(s.easels[easel]?.title, "Moodboard")
        XCTAssertEqual(s.easels[easel]?.meta.modifiedAt(Easel.FieldGroup.naming), at(5))
        XCTAssertEqual(s.tabs[row]?.title, "Moodboard")
        XCTAssertNil(s.tabs[row]?.customTitle, "the row shows the Easel's title")
        XCTAssertEqual(s.tabs[row]?.meta.modifiedAt(TabNode.FieldGroup.content), at(5))
        XCTAssertEqual(s.tabs[row]?.meta.modifiedAt(TabNode.FieldGroup.placement), before.tabs[row]?.meta.modifiedAt(TabNode.FieldGroup.placement))
        // A blank title goes back to the default. inferred.
        s = try TreeOps.renameEasel(s, id: easel, title: "   ", now: at(6))
        XCTAssertEqual(s.easels[easel]?.title, "Untitled Easel")
        // Same title: nothing changes.
        XCTAssertEqual(try TreeOps.renameEasel(s, id: easel, title: "Untitled Easel", now: at(7)), s)
    }

    // MARK: Elements [06 §9]

    /// [06 §9] observed tools: image, text, circle, rectangle, arrow, pen. Each kind is stored
    /// with its frame and style; later elements stack on top.
    func testAddEveryElementKindStacksOnTop() throws {
        var s = try withEasel()
        let image = EaselImage(data: Data([0x89, 0x50, 0x4E, 0x47]), format: .png, pixelWidth: 2, pixelHeight: 2)
        let contents: [EaselElementContent] = [
            .image(image), .text(string: "Hi"), .circle, .rectangle,
            .arrow(start: EaselPoint(x: 0, y: 0), end: EaselPoint(x: 1, y: 1)),
            .pen(points: [EaselPoint(x: 0, y: 0), EaselPoint(x: 0.5, y: 0.2), EaselPoint(x: 1, y: 1)]),
        ]
        var ids: [UUID] = []
        for (i, content) in contents.enumerated() {
            let id = UUID()
            ids.append(id)
            s = try TreeOps.addEaselElement(s, id: id, easelID: easel, frame: rect(Double(i)), content: content, style: style, now: at(Double(10 + i)))
        }
        let elements = s.elements(inEasel: easel)
        XCTAssertEqual(elements.map(\.id), ids)
        XCTAssertEqual(elements.map(\.content.kind), EaselElementKind.allCases)
        XCTAssertEqual(elements[2].frame, rect(2))
    }

    func testAddToMissingOrDeletedEaselThrows() throws {
        let s = try withEasel()
        XCTAssertThrowsError(try TreeOps.addEaselElement(s, id: e1, easelID: UUID(), frame: rect(0), content: .circle, style: style, now: at(2)))
        let deleted = try TreeOps.deleteEasel(s, id: easel, now: at(2))
        XCTAssertThrowsError(try TreeOps.addEaselElement(deleted, id: e1, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(3))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(easel))
        }
    }

    /// Each edit stamps only its own group, so concurrent edits of different aspects merge.
    func testElementEditsStampOnlyTheirGroup() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .text(string: "a"), style: style, now: at(2))
        func times(_ s: WorkspaceState) -> [String: Date] { s.easelElements[e1]?.meta.fieldGroupModifiedAt ?? [:] }

        let moved = try TreeOps.setEaselElementFrame(s, id: e1, frame: rect(5), now: at(3))
        XCTAssertEqual(times(moved), times(s).merging(["geometry": at(3)]) { $1 })
        let edited = try TreeOps.setEaselElementContent(s, id: e1, content: .text(string: "b"), now: at(4))
        XCTAssertEqual(times(edited), times(s).merging(["content": at(4)]) { $1 })
        var restyled = style
        restyled.strokeWidth = 6
        let styled = try TreeOps.setEaselElementStyle(s, id: e1, style: restyled, now: at(5))
        XCTAssertEqual(times(styled), times(s).merging(["style": at(5)]) { $1 })
        // No-op edits leave the record alone.
        XCTAssertEqual(try TreeOps.setEaselElementFrame(s, id: e1, frame: rect(0), now: at(9)), s)
    }

    func testMoveSeveralElements() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        s = try TreeOps.addEaselElement(s, id: e2, easelID: easel, frame: rect(20), content: .rectangle, style: style, now: at(2))
        s = try TreeOps.moveEaselElements(s, ids: [e1, e2], dx: 5, dy: -3, now: at(3))
        XCTAssertEqual(s.easelElements[e1]?.frame, EaselRect(x: 5, y: -3, width: 10, height: 10))
        XCTAssertEqual(s.easelElements[e2]?.frame, EaselRect(x: 25, y: 17, width: 10, height: 10))
    }

    func testReorderChangesStackingOnlyPlacement() throws {
        var s = try withEasel()
        for id in [e1, e2, e3] {
            s = try TreeOps.addEaselElement(s, id: id, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        }
        s = try TreeOps.reorderEaselElement(s, id: e3, position: .first, now: at(4))
        XCTAssertEqual(s.elements(inEasel: easel).map(\.id), [e3, e1, e2])
        XCTAssertEqual(s.easelElements[e3]?.meta.modifiedAt(EaselElement.FieldGroup.placement), at(4))
        XCTAssertEqual(s.easelElements[e3]?.meta.modifiedAt(EaselElement.FieldGroup.geometry), at(2))
        s = try TreeOps.reorderEaselElement(s, id: e3, position: .after(e1), now: at(5))
        XCTAssertEqual(s.elements(inEasel: easel).map(\.id), [e1, e3, e2])
    }

    func testDeleteElementsTombstones() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        s = try TreeOps.addEaselElement(s, id: e2, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        s = try TreeOps.deleteEaselElements(s, ids: [e1], now: at(3))
        XCTAssertEqual(s.easelElements[e1]?.meta.isTombstone, true, "deleted by tombstone, not removed")
        XCTAssertEqual(s.elements(inEasel: easel).map(\.id), [e2])
        XCTAssertThrowsError(try TreeOps.deleteEaselElements(s, ids: [e1], now: at(4)))
    }

    // MARK: Delete, Space deletion [06 §11]

    /// Deleting an Easel tombstones it, its elements and its rows.
    func testDeleteEaselTombstonesElementsAndRows() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        s = try TreeOps.addEaselRow(s, easelID: easel, tabID: e2, spaceID: work, now: at(3))
        s = try TreeOps.deleteEasel(s, id: easel, now: at(4))
        XCTAssertEqual(s.easels[easel]?.meta.isTombstone, true)
        XCTAssertEqual(s.easelElements[e1]?.meta.isTombstone, true)
        XCTAssertEqual(s.tabs[row]?.meta.isTombstone, true)
        XCTAssertEqual(s.tabs[e2]?.meta.isTombstone, true)
        XCTAssertTrue(s.liveEaselsNewestFirst.isEmpty)
        XCTAssertTrue(s.elements(inEasel: easel).isEmpty)
    }

    /// [06 §11] observed: Library ▸ Easels still lists an Easel after its Space was deleted.
    func testEaselOutlivesItsSpace() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .circle, style: style, now: at(2))
        s = try TreeOps.deleteSpace(s, id: home, now: at(3))
        XCTAssertEqual(s.liveEaselsNewestFirst.map(\.id), [easel])
        XCTAssertEqual(s.elements(inEasel: easel).map(\.id), [e1])
        XCTAssertTrue(s.tabs(showingEasel: easel).isEmpty, "the row went with its Space")
        // Opening it again adds a row in the current Space.
        s = try TreeOps.addEaselRow(s, easelID: easel, tabID: e3, spaceID: work, now: at(4))
        XCTAssertEqual(s.tabs[e3]?.location, .pinned(spaceID: work, folderID: nil))
        XCTAssertEqual(s.easelID(ofTab: e3), easel)
    }

    /// Archiving the row keeps the Easel (the archive item keeps the link).
    func testArchivingTheRowKeepsTheEasel() throws {
        var s = try withEasel()
        s = try TreeOps.archiveTab(s, id: row, now: at(2))
        XCTAssertNotNil(s.liveEasel(easel))
        XCTAssertEqual(s.archive[row]?.url, EaselLink.url(for: easel))
    }

    // MARK: Codable

    func testWorkspaceWithEaselsRoundTripsAndOldDataDecodes() throws {
        var s = try withEasel()
        s = try TreeOps.addEaselElement(s, id: e1, easelID: easel, frame: rect(0), content: .pen(points: [EaselPoint(x: 0.1, y: 0.2)]), style: style, now: at(2))
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: data), s)

        // Data written before Easels existed has no such keys.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["easels"] = nil
        json["easelElements"] = nil
        let old = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.easels.isEmpty)
        XCTAssertTrue(old.easelElements.isEmpty)
        XCTAssertEqual(old.tabs, s.tabs)
    }

    /// Record type names and field groups are persisted schema.
    func testPersistedNames() {
        XCTAssertEqual(Easel.recordTypeName, "Easel")
        XCTAssertEqual(EaselElement.recordTypeName, "EaselElement")
        XCTAssertEqual(Easel.FieldGroup.allCases.map(\.rawValue), ["naming"])
        XCTAssertEqual(EaselElement.FieldGroup.allCases.map(\.rawValue), ["placement", "geometry", "content", "style"])
    }

    func testImageInlineLimit() {
        XCTAssertTrue(EaselImage(data: Data(count: EaselImage.maxEncodedBytes), format: .png, pixelWidth: 1, pixelHeight: 1).fitsInlineLimit)
        XCTAssertFalse(EaselImage(data: Data(count: EaselImage.maxEncodedBytes + 1), format: .jpeg, pixelWidth: 1, pixelHeight: 1).fitsInlineLimit)
    }
}
