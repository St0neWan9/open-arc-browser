import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Sidebar items of plan rows B134 / B136 (F5 comparison, `docs/f5-review.md`): favorite Rename…
/// ([06 §21.5]), the rename flag never left set, ✕ on the selected row ([06 §12], [06 §20.2]), the
/// Today divider rule ([06 §4], [04 §侧边栏]), peek fill and rim ([04 §收起侧边栏], [06 §26.2]),
/// split row capsules ([06 §21.6]), folder glyph ([07 §4]), New Tab row selected fill
/// ([06 §20.1], [07 §4]) and the pinned '—' button ([06 §16.1]).
@MainActor
final class SidebarF5B134Tests: XCTestCase {

    // MARK: F5-1 favorite Rename…

    /// [06 §21.5] observed: the favorite menu has Rename…. A favorite tile shows only its icon
    /// ([06 §21.3]), so Rename… opens the rename card instead of setting the inline rename flag;
    /// the card renames the favorite, and a blank title puts the page title back.
    func testFavoriteRenameOpensCardAndRenames_06_21_5() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(f.fav1)
        XCTAssertNil(vm.renamingItemID, "no inline field on a favorite tile")
        XCTAssertEqual(vm.favoriteRenameTabID, f.fav1)
        vm.commitFavoriteRename(text: "  Mail ")
        XCTAssertNil(vm.favoriteRenameTabID)
        XCTAssertEqual(vm.workspace.tabs[f.fav1]?.displayTitle, "Mail")
        vm.beginRename(f.fav1)
        vm.commitFavoriteRename(text: " ")
        XCTAssertEqual(vm.workspace.tabs[f.fav1]?.displayTitle, "fav1.example.com")
        vm.beginRename(f.fav1)
        vm.cancelFavoriteRename()
        XCTAssertNil(vm.favoriteRenameTabID)
        XCTAssertEqual(vm.workspace.tabs[f.fav1]?.displayTitle, "fav1.example.com")
        vm.stop()
    }

    /// The favorite rename card is a window card at the New Folder size ([07 §12] observed cards).
    func testFavoriteRenameCardIsAWindowCard_06_21_5() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(f.fav2)
        let host = NSHostingView(rootView: Color.clear.frame(width: 800, height: 600)
            .modifier(SidebarWindowModals(sidebar: vm))
            .onPreferenceChange(WindowModalSummaryKey.self) { summaries in
                MainActor.assumeIsolated { SidebarF5B134Tests.lastSummaries = summaries }
            })
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(Self.lastSummaries, [WindowModalSummary(id: "renameFavorite", size: Metrics.Dialog.newFolderSize)])
        vm.stop()
    }
    private static var lastSummaries: [WindowModalSummary] = []

    /// F5-1: the rename flag is only set for an item with a row on screen, so it can never stay
    /// set with no field to end it (it turns off hover cards, press-to-select and quick lists).
    func testRenameFlagNeverSetWithoutARow_06_21_5() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(f.workTab)
        XCTAssertNil(vm.renamingItemID, "a tab of another Space has no row here")
        vm.beginRename(SidebarFixture.id(999))
        XCTAssertNil(vm.renamingItemID)
        vm.setAllFoldersExpanded(false)
        vm.beginRename(f.deepTab)
        XCTAssertNil(vm.renamingItemID, "hidden in a collapsed folder")
        vm.stop()
    }

    /// F5-1: a rename whose row goes away (archived here or from another window) ends.
    func testRenameEndsWhenItsRowGoesAway() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(f.today2)
        XCTAssertEqual(vm.renamingItemID, f.today2)
        vm.replaceWorkspace(try TreeOps.archiveTab(vm.workspace, id: f.today2, now: f.now))
        XCTAssertNil(vm.renamingItemID)
        vm.beginRename(f.fav1)
        vm.replaceWorkspace(try TreeOps.archiveTab(vm.workspace, id: f.fav1, now: f.now))
        XCTAssertNil(vm.favoriteRenameTabID)
        vm.stop()
    }

    /// F5-1: a press on another row ends the rename (the field commits as it closes), so the
    /// press selects as usual; a field that closes on its own cancels.
    func testPressElsewhereEndsRenameAndCommits() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.beginRename(f.today1)
        vm.pressSelect(.tab(f.today2))
        XCTAssertNil(vm.renamingItemID)
        XCTAssertEqual(vm.selectedTabID, f.today2, "the press selects the other row")
        vm.renameFieldClosed(f.today1, text: "Typed")
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.displayTitle, "Typed")
        // A field that disappears without a press elsewhere cancels.
        vm.beginRename(f.today3)
        vm.renameFieldClosed(f.today3, text: "Dropped")
        XCTAssertNil(vm.renamingItemID)
        XCTAssertEqual(vm.workspace.tabs[f.today3]?.displayTitle, "today3")
        // Hover cards work again once the rename ended.
        vm.hoverDelay = 0
        vm.hoverBegan(f.today1)
        XCTAssertNotNil(vm.hoverTask)
        vm.stop()
    }

    // MARK: F5-13 ✕ on the selected row

    /// [06 §12] observed (hover), [06 §20.2] observed (hover / selected): the ✕ (— on a pinned
    /// row) shows on the selected row too; never while renaming.
    func testAccessoryShowsWhenHoveredOrSelected_06_20_2() {
        XCTAssertFalse(SidebarTabRowView.showsAccessory(isHovering: false, isSelected: false, isRenaming: false))
        XCTAssertTrue(SidebarTabRowView.showsAccessory(isHovering: true, isSelected: false, isRenaming: false))
        XCTAssertTrue(SidebarTabRowView.showsAccessory(isHovering: false, isSelected: true, isRenaming: false))
        XCTAssertFalse(SidebarTabRowView.showsAccessory(isHovering: true, isSelected: true, isRenaming: true))
    }

    /// [06 §20.2]: the selected row's state carries the selection the ✕ follows, without hover.
    func testSelectedRowStateShowsAccessory_06_20_2() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.pinnedTab)
        let tab = vm.workspace.tabs[f.pinnedTab]!
        let selected = vm.tabRowState(tab, depth: 0, area: .pinned, palette: vm.palette)
        XCTAssertTrue(SidebarTabRowView.showsAccessory(isHovering: false, isSelected: selected.isSelected, isRenaming: selected.isRenaming))
        let other = vm.tabRowState(vm.workspace.tabs[f.today1]!, depth: 0, area: .today, palette: vm.palette)
        XCTAssertFalse(SidebarTabRowView.showsAccessory(isHovering: false, isSelected: other.isSelected, isRenaming: other.isRenaming))
        vm.beginRename(f.pinnedTab)
        let renaming = vm.tabRowState(tab, depth: 0, area: .pinned, palette: vm.palette)
        XCTAssertFalse(SidebarTabRowView.showsAccessory(isHovering: true, isSelected: renaming.isSelected, isRenaming: renaming.isRenaming))
        vm.cancelRename()
        vm.stop()
    }

    // MARK: F5-43 Today divider

    /// [06 §4], [04 §侧边栏 Today 区分隔线] observed: the divider separates pinned tabs from Today;
    /// an empty Space has none ([06 §4]) and incognito has none ([06 §20.2]). Our rule (Today has
    /// tabs) is kept: [06 §4]'s "only when the pinned area has content" contradicts its own example
    /// of the divider above a Today tab with no pinned items (F5-43, a spec fix).
    func testDividerFollowsTodayTabs_06_4() throws {
        let f = SidebarFixture()
        var ws = f.ws
        // No pinned content, a Today tab: the divider shows (the example of [06 §4]).
        ws = try TreeOps.openTab(ws, id: SidebarFixture.id(950), spaceID: f.work, url: nil, title: "x", now: f.now)
        let workSnap = SidebarSnapshot.make(workspace: ws, spaceID: f.work, profileID: f.profile)
        XCTAssertFalse(workSnap.hasPinnedContent)
        XCTAssertTrue(workSnap.showsDivider)
        // Pinned content, empty Today: no divider row (reference AX tree, B16).
        let cleared = try TreeOps.clearToday(ws, spaceID: f.home, now: f.now)
        XCTAssertFalse(SidebarSnapshot.make(workspace: cleared, spaceID: f.home, profileID: f.profile).showsDivider)
    }

    // MARK: F5-8/17/19, F5-18/30 peek panel

    /// [04 §收起侧边栏], [06 §26.2] observed (dark, default theme): pinned sidebar #2C283E, floating
    /// panel ≈ #1D1B32 with a ≈ 2 pt light rim ≈ #5D5F70. Within 4/255 per channel.
    func testPeekPanelFillAndRimOnDefaultDarkTheme_06_26_2() {
        let fill = SidebarPeekTokens.panelFill(for: RGBAColor(hex: 0x2C283E), isDark: true)
        assertClose(fill, RGBAColor(hex: 0x1D1B32), tolerance: 4)
        let rim = SidebarPeekTokens.rimOver(fill, isDark: true)
        assertClose(rim, RGBAColor(hex: 0x5D5F70), tolerance: 4)
        XCTAssertEqual(SidebarPeekTokens.rimWidth, 2)
    }

    /// [06 §14] observed: "slightly deeper, more saturated" in the light appearance too; light
    /// themes keep a mild change and a dark (not white) rim.
    func testPeekPanelLightThemeStaysClose_06_14() {
        let window = ThemeDerivation.lightWindow(RGBAColor(hex: 0x8E6FD8))
        let fill = SidebarPeekTokens.panelFill(for: window, isDark: false)
        XCTAssertLessThan(ThemeDerivation.luminance(fill), ThemeDerivation.luminance(window))
        XCTAssertGreaterThan(ThemeDerivation.luminance(fill), ThemeDerivation.luminance(window) * 0.85, "slightly deeper")
        XCTAssertLessThan(ThemeDerivation.luminance(SidebarPeekTokens.rimOver(fill, isDark: false)), ThemeDerivation.luminance(fill))
    }

    // MARK: F5-15 split row capsules

    /// [06 §21.6] observed: one capsule per member, side by side, each with icon and title. The
    /// row state has one member entry per capsule; a capsule fits inside the 40 pt row button and
    /// the first icon stays at the row icon position (x 17) (our capsule metrics, unknown).
    func testSplitRowHasOneCapsulePerMember_06_21_6() throws {
        var f = SidebarFixture()
        let layoutID = SidebarFixture.id(960)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        let group = try XCTUnwrap(vm.snapshot.splitGroup(layoutID: layoutID))
        let state = vm.splitGroupRowState(group, depth: 0, area: .today, palette: vm.palette)
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(state.members.count, group.members.count)
        let t = SidebarLocalTokens.self
        XCTAssertLessThan(t.splitGroupCapsuleHeight, SidebarLayout().rowButtonHeight)
        let firstCapsuleMinX = SidebarLayout().rowIconLeading - t.splitGroupCapsuleLeading
        XCTAssertEqual(firstCapsuleMinX + t.splitGroupCapsuleLeading, 17)
        XCTAssertGreaterThanOrEqual(firstCapsuleMinX, SidebarLayout().rowFillFrame.minX, "inside the row fill")
        vm.stop()
    }

    // MARK: F5-32/49/59 folder glyph

    /// [07 §4] observed: folder ink 22.5 × 16.5 at x 16–38.5, centered on the row; the glyph
    /// uses `Metrics.Sidebar.folderGlyph`.
    func testFolderGlyphUsesMeasuredInk_07_4() {
        XCTAssertEqual(SidebarFolderGlyph.inkSize, CGSize(width: 22.5, height: 16.5))
        let cellLeading = CGFloat(Metrics.Sidebar.rowIconLeading)
        let cellCenter = cellLeading + CGFloat(Metrics.Sidebar.rowIconSize) / 2
        let inkMinX = cellCenter + SidebarFolderGlyph.inkOffsetX - SidebarFolderGlyph.inkSize.width / 2
        XCTAssertEqual(inkMinX, 16, accuracy: 0.01)
        XCTAssertEqual(inkMinX + SidebarFolderGlyph.inkSize.width, 38.5, accuracy: 0.01)
    }

    // MARK: F5-66 New Tab row selected fill

    /// [06 §20.1] observed: the incognito New Tab row fill while selected ≈ #46494D; [04 §侧边栏]
    /// observed: the row's fill is the address box's; [07 §4]: no fill while unselected.
    func testNewTabRowSelectedFill_06_20_1() {
        let palette = ThemeDerivation.incognitoPalette(appearance: .dark)
        XCTAssertEqual(SidebarNewTabRowView.selectedFill(palette: palette, isIncognito: true), RGBAColor(hex: 0x46494D))
        let normal = ThemeDerivation.palette(for: nil, appearance: .light)
        XCTAssertEqual(SidebarNewTabRowView.selectedFill(palette: normal, isIncognito: false), normal.windowFills(on: .opaque).controlFill)
    }

    /// The row is selected while the window's new-tab command bar is open (inferred), not for ⌘L.
    func testNewTabRowSelectedWhileNewTabBarIsOpen_06_20_1() {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        defer { model.stop() }
        XCTAssertFalse(model.sidebar.isNewTabRowSelected)
        model.presentCommandBar(.newTab)
        XCTAssertTrue(model.sidebar.isNewTabRowSelected)
        model.dismissCommandBar()
        XCTAssertFalse(model.sidebar.isNewTabRowSelected)
        model.presentCommandBar(.currentTab)
        XCTAssertFalse(model.sidebar.isNewTabRowSelected)
        model.dismissCommandBar()
    }

    // MARK: F5-37/38 pinned row '—'

    /// [06 §16.1] observed: a 26 × 26 button ≈ 13 pt from the row's right edge (x 276), so its
    /// right edge is at x 263: the 268 fill edge minus the trailing padding.
    func testPinnedRowButtonSizeAndPlace_06_16_1() {
        XCTAssertEqual(SidebarLocalTokens.rowAccessoryButtonSize, 26)
        let fillMaxX = SidebarLayout().rowFillFrame.maxX
        XCTAssertEqual(CGFloat(Metrics.Sidebar.width) - (fillMaxX - SidebarLocalTokens.rowAccessoryTrailingPadding), 13)
    }

    private func assertClose(_ a: RGBAColor, _ b: RGBAColor, tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red * 255, b.red * 255, accuracy: tolerance, "red", file: file, line: line)
        XCTAssertEqual(a.green * 255, b.green * 255, accuracy: tolerance, "green", file: file, line: line)
        XCTAssertEqual(a.blue * 255, b.blue * 255, accuracy: tolerance, "blue", file: file, line: line)
    }
}
