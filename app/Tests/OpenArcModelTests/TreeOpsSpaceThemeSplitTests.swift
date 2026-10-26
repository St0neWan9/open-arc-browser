import XCTest
@testable import OpenArcModel

/// Space and theme edits, `moveSplitLayout`, the auto-archive exclusion set and the
/// `Theme.brightness` field (A17).
final class TreeOpsSpaceThemeSplitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let profile = UUID(), home = UUID(), work = UUID()

    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: t0)
        s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", now: t0)
        return s
    }

    /// Group timestamps of a record, for "only these groups changed" checks.
    private func groupTimes<T: SyncableEntity>(_ value: T?) -> [String: Date] { value?.meta.fieldGroupModifiedAt ?? [:] }

    // MARK: Space edits [01 §Spaces], [05 §context menus], [06 §1]

    /// [01 §Spaces] observed (Rename Space): stamps only `naming`.
    func testRenameSpaceStampsOnlyNaming() throws {
        let s0 = try base()
        let s = try TreeOps.renameSpace(s0, id: home, name: "Base", now: at(10))
        XCTAssertEqual(s.spaces[home]?.name, "Base")
        var expected = groupTimes(s0.spaces[home])
        expected[Space.FieldGroup.naming.rawValue] = at(10)
        XCTAssertEqual(groupTimes(s.spaces[home]), expected)
        XCTAssertEqual(s.spaces[work], s0.spaces[work])
    }

    /// [05 §context menus] observed (Change Space Icon…): stamps only `naming`; nil clears.
    func testSetSpaceIconStampsOnlyNamingAndCanClear() throws {
        let s0 = try base()
        let s1 = try TreeOps.setSpaceIcon(s0, id: home, icon: "🏠", now: at(10))
        XCTAssertEqual(s1.spaces[home]?.icon, "🏠")
        var expected = groupTimes(s0.spaces[home])
        expected[Space.FieldGroup.naming.rawValue] = at(10)
        XCTAssertEqual(groupTimes(s1.spaces[home]), expected)
        let s2 = try TreeOps.setSpaceIcon(s1, id: home, icon: nil, now: at(20))
        XCTAssertNil(s2.spaces[home]?.icon)
    }

    /// Edits of a tombstoned or missing space throw and change nothing.
    func testSpaceEditsRejectTombstonedAndMissingSpaces() throws {
        let s = try TreeOps.deleteSpace(try base(), id: work, now: at(5))
        XCTAssertThrowsError(try TreeOps.renameSpace(s, id: work, name: "X", now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(work))
        }
        XCTAssertThrowsError(try TreeOps.setSpaceIcon(s, id: work, icon: "x", now: at(10)))
        XCTAssertThrowsError(try TreeOps.setSpaceTheme(s, id: work, themeID: nil, now: at(10)))
        let missing = UUID()
        XCTAssertThrowsError(try TreeOps.renameSpace(s, id: missing, name: "X", now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .notFound(missing))
        }
    }

    /// [06 §1] observed: a space without a theme uses the default; setting a theme stamps only
    /// `Space.theme`, and a tombstoned theme is refused.
    func testSetSpaceThemeStampsOnlyThemeAndNeedsLiveTheme() throws {
        let theme = UUID()
        let s0 = TreeOps.createTheme(try base(), id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x112233)]), now: t0)
        let s1 = try TreeOps.setSpaceTheme(s0, id: home, themeID: theme, now: at(10))
        XCTAssertEqual(s1.spaces[home]?.themeID, theme)
        var expected = groupTimes(s0.spaces[home])
        expected[Space.FieldGroup.theme.rawValue] = at(10)
        XCTAssertEqual(groupTimes(s1.spaces[home]), expected)
        let s2 = try TreeOps.setSpaceTheme(s1, id: home, themeID: nil, now: at(20))
        XCTAssertNil(s2.spaces[home]?.themeID)

        var dead = s0
        dead.themes[theme]?.meta.markDeleted(at: at(1))
        XCTAssertThrowsError(try TreeOps.setSpaceTheme(dead, id: home, themeID: theme, now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(theme))
        }
    }

    // MARK: Themes [06 §2]

    /// [06 §2] observed: a theme has appearance, color dots, texture and the knob value.
    func testCreateThemeStoresTheWholeStyle() throws {
        let id = UUID()
        let style = ThemeStyle(appearance: .dark, colors: [RGBAColor(hex: 0xABCDEF)], grain: 0.3, brightness: 0.8)
        let s = TreeOps.createTheme(try base(), id: id, style: style, now: at(3))
        let theme = try XCTUnwrap(s.themes[id])
        XCTAssertEqual(theme.style, style)
        XCTAssertEqual(theme.meta.modifiedAt(Theme.FieldGroup.style), at(3))
    }

    /// [06 §2] observed (live edits in the bubble): only `Theme.style` is stamped, and an unchanged
    /// style is a no-op (no stamp, no version bump).
    func testEditThemeStampsOnlyStyleAndUnchangedIsNoOp() throws {
        let id = UUID()
        let s0 = TreeOps.createTheme(try base(), id: id, style: ThemeStyle(colors: [RGBAColor(hex: 0x112233)]), now: t0)
        var style = try XCTUnwrap(s0.themes[id]).style
        XCTAssertEqual(try TreeOps.editTheme(s0, id: id, style: style, now: at(10)), s0)

        style.brightness = 0.2
        style.grain = 0.7
        let s1 = try TreeOps.editTheme(s0, id: id, style: style, now: at(10))
        let theme = try XCTUnwrap(s1.themes[id])
        XCTAssertEqual(theme.brightness, 0.2)
        XCTAssertEqual(theme.grain, 0.7)
        XCTAssertEqual(theme.meta.modifiedAt(Theme.FieldGroup.style), at(10))
        XCTAssertEqual(theme.meta.version, s0.themes[id]!.meta.version + 1)
        XCTAssertEqual(s1.spaces, s0.spaces, "spaces are untouched")
    }

    /// [06 §2] observed (Edit Theme…): a space with a live theme edits that theme; a space without
    /// one (or with a tombstoned one) gets a new theme, which stamps `Space.theme`.
    func testEditSpaceThemeEditsOrCreates() throws {
        let newTheme = UUID(), replacement = UUID()
        let style = ThemeStyle(colors: [RGBAColor(hex: 0x445566)], brightness: 0.6)
        let s1 = try TreeOps.editSpaceTheme(try base(), spaceID: home, newThemeID: newTheme, style: style, now: at(10))
        XCTAssertEqual(s1.spaces[home]?.themeID, newTheme)
        XCTAssertEqual(s1.themes[newTheme]?.style, style)
        XCTAssertEqual(s1.spaces[home]?.meta.modifiedAt(Space.FieldGroup.theme), at(10))

        var edited = style
        edited.colors = [RGBAColor(hex: 0x778899)]
        let s2 = try TreeOps.editSpaceTheme(s1, spaceID: home, newThemeID: replacement, style: edited, now: at(20))
        XCTAssertEqual(s2.spaces[home], s1.spaces[home], "the space is not stamped again")
        XCTAssertEqual(s2.themes[newTheme]?.colors, edited.colors)
        XCTAssertNil(s2.themes[replacement])

        var dead = s2
        dead.themes[newTheme]?.meta.markDeleted(at: at(25))
        let s3 = try TreeOps.editSpaceTheme(dead, spaceID: home, newThemeID: replacement, style: style, now: at(30))
        XCTAssertEqual(s3.spaces[home]?.themeID, replacement)
        XCTAssertEqual(s3.themes[newTheme]?.meta.isTombstone, true, "the tombstone stays a tombstone")

        let missing = UUID()
        XCTAssertThrowsError(try TreeOps.editSpaceTheme(s3, spaceID: missing, newThemeID: UUID(), style: style, now: at(40))) {
            XCTAssertEqual($0 as? TreeError, .notFound(missing))
        }
    }

    /// Inferred default: 0.5 is the neutral knob. Data written before the field existed decodes
    /// with it, and a round trip keeps a set value.
    func testThemeBrightnessDefaultsAndDecodesOldData() throws {
        let theme = Theme(id: UUID(), colors: [RGBAColor(hex: 0x123456)], now: t0)
        XCTAssertEqual(theme.brightness, 0.5)
        XCTAssertEqual(Theme.defaultBrightness, 0.5)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "brightness"))
        let old = try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old, theme)

        var bright = theme
        bright.brightness = 0.9
        XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(bright)), bright)
    }

    // MARK: Split across spaces [06 §5]

    /// Pinned tab A and Today tab B split in `home`; plus a Today tab C in `work`.
    private func splitState() throws -> (WorkspaceState, layout: UUID, a: UUID, b: UUID, c: UUID) {
        let a = UUID(), b = UUID(), c = UUID(), layout = UUID()
        var s = try base()
        s = try TreeOps.openTab(s, id: a, spaceID: home, url: URL(string: "https://a.example"), title: "A", now: t0)
        s = try TreeOps.pinTab(s, id: a, now: t0)
        s = try TreeOps.openTab(s, id: b, spaceID: home, url: nil, title: "B", now: t0)
        s = try TreeOps.openTab(s, id: c, spaceID: work, url: nil, title: "C", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: b, newTabID: a, now: t0)
        return (s, layout, a, b, c)
    }

    /// [06 §5] observed: the split tabs are one group, so a cross-space move takes every member
    /// and the layout together; landing at the top of Today is inferred (like a single tab).
    func testMoveSplitLayoutMovesMembersAndLayoutTogether() throws {
        let (s0, layout, a, b, c) = try splitState()
        let s = try TreeOps.moveSplitLayout(s0, layoutID: layout, toSpaceID: work, position: .first, now: at(10))
        XCTAssertEqual(s.splits[layout]?.spaceID, work)
        XCTAssertEqual(s.splits[layout]?.root, s0.splits[layout]?.root, "pane order and fractions are kept")
        XCTAssertEqual(s.splits[layout]?.meta.modifiedAt(SplitLayout.FieldGroup.layout), at(10))
        // Pinned members first, then Today members; both land above C.
        XCTAssertEqual(s.today(spaceID: work).map(\.id), [a, b, c])
        XCTAssertTrue(s.allTabs(inSpace: home).isEmpty)
        // Only placement is stamped on the members (A already had a pinned URL).
        for id in [a, b] {
            var expected = groupTimes(s0.tabs[id])
            expected[TabNode.FieldGroup.placement.rawValue] = at(10)
            XCTAssertEqual(groupTimes(s.tabs[id]), expected)
        }
        XCTAssertEqual(s.tabs[c]?.meta.fieldGroupModifiedAt, s0.tabs[c]?.meta.fieldGroupModifiedAt)

        let after = try TreeOps.moveSplitLayout(s0, layoutID: layout, toSpaceID: work, position: .after(c), now: at(10))
        XCTAssertEqual(after.today(spaceID: work).map(\.id), [c, a, b])
    }

    /// Within the same space the members are gathered in Today and the layout is not stamped.
    func testMoveSplitLayoutWithinSameSpaceDoesNotStampLayout() throws {
        let (s0, layout, a, b, _) = try splitState()
        let s = try TreeOps.moveSplitLayout(s0, layoutID: layout, toSpaceID: home, position: .last, now: at(10))
        XCTAssertEqual(s.splits[layout], s0.splits[layout])
        XCTAssertEqual(s.today(spaceID: home).map(\.id), [a, b])
    }

    /// Invalid input throws and leaves nothing half-moved.
    func testMoveSplitLayoutRejectsBadInput() throws {
        let (s0, layout, a, _, _) = try splitState()
        XCTAssertThrowsError(try TreeOps.moveSplitLayout(s0, layoutID: UUID(), toSpaceID: work, position: .first, now: at(10)))
        let gone = try TreeOps.deleteSpace(s0, id: work, now: at(5))
        XCTAssertThrowsError(try TreeOps.moveSplitLayout(gone, layoutID: layout, toSpaceID: work, position: .first, now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(self.work))
        }
        XCTAssertThrowsError(try TreeOps.moveSplitLayout(s0, layoutID: layout, toSpaceID: work, position: .after(a), now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .anchorNotInContainer(a))
        }
        var dead = s0
        dead.splits[layout]?.meta.markDeleted(at: at(1))
        XCTAssertThrowsError(try TreeOps.moveSplitLayout(dead, layoutID: layout, toSpaceID: work, position: .first, now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(layout))
        }
    }

    // MARK: Auto-archive exclusion [05 §window and app entry points]

    /// [05 §window and app entry points] observed 12 h lifetime; excluding tabs on screen is
    /// inferred. Excluded tabs are neither archived nor stamped.
    func testAutoArchiveSkipsExcludedTabsWithoutStamping() throws {
        let kept = UUID(), stale = UUID()
        var s = try base()
        s = try TreeOps.openTab(s, id: kept, spaceID: home, url: nil, title: "", now: t0)
        s = try TreeOps.openTab(s, id: stale, spaceID: home, url: nil, title: "", now: t0)
        let out = TreeOps.autoArchive(s, excluding: [kept], now: at(13 * 3600))
        XCTAssertEqual(out.tabs[kept], s.tabs[kept])
        XCTAssertNil(out.archive[kept])
        XCTAssertEqual(out.archive[stale]?.reason, .autoArchived)
        // Default: nothing excluded.
        XCTAssertEqual(TreeOps.autoArchive(s, now: at(13 * 3600)).archive[kept]?.reason, .autoArchived)
    }

    // MARK: Split side [06 §17.3]

    /// [06 §17.3] observed: the web toolbar's split menu adds a pane right, left, top or bottom.
    /// `side` puts the new pane before or after the existing one, in a new layout and in an
    /// existing one; the default stays "after" (⌃⇧=, [06 §5]). Only `layout` is stamped.
    func testAddSplitPaneOnEitherSide() throws {
        let a = UUID(), b = UUID(), c = UUID(), layout = UUID()
        var s = try base()
        for (id, title) in [(a, "A"), (b, "B"), (c, "C")] {
            s = try TreeOps.openTab(s, id: id, spaceID: home, url: nil, title: title, now: t0)
        }
        let left = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: a, newTabID: b, side: .leading, now: at(1))
        XCTAssertEqual(left.splits[layout]?.root.tabIDs, [b, a])
        let top = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: a, newTabID: b, axis: .vertical, side: .leading, now: at(1))
        guard case .split(let axis, _) = top.splits[layout]?.root else { return XCTFail("no split") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(top.splits[layout]?.root.tabIDs, [b, a])
        let right = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: a, newTabID: b, now: at(1))
        XCTAssertEqual(right.splits[layout]?.root.tabIDs, [a, b])
        // Joining an existing layout: before the existing pane.
        let three = try TreeOps.addSplitPane(right, layoutID: UUID(), existingTabID: b, newTabID: c, side: .leading, now: at(2))
        XCTAssertEqual(three.splits[layout]?.root.tabIDs, [a, c, b])
        XCTAssertEqual(groupTimes(three.splits[layout])[SplitLayout.FieldGroup.layout.rawValue], at(2))
    }
}
