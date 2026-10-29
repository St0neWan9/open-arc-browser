import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Create Space, Rename Space and Change Space Icon. Acceptance: `06 §1`, `01 §Spaces`,
/// `05 §context menus` (Space background menu).
@MainActor
final class SpaceFlowTests: XCTestCase {
    private var fixture = SidebarFixture()
    private var counter = 1000
    private let later = Date(timeIntervalSince1970: 2_000)
    /// Injected clock; starts at the fixture time and can be advanced by a test.
    private lazy var clock = fixture.now

    private func makeModel(selecting spaceID: UUID? = nil) -> ShellModel {
        // The fixed clock equals the fixture time, so launch auto-archive cannot expire anything.
        let model = ShellModel(
            dependencies: .fake(),
            workspace: fixture.ws,
            now: { [unowned self] in self.clock },
            makeID: { [unowned self] in
                self.counter += 1
                return SidebarFixture.id(self.counter)
            }
        )
        if let spaceID { model.selectSpace(spaceID) }
        return model
    }

    private func dockNames(_ model: ShellModel) -> [String] { model.sidebar.dockSpaces.map(\.name) }

    // MARK: Create Space [06 §1]

    /// [06 §1] observed: the dock "+" and Spaces ▸ New Space… show the creation view, which starts empty.
    func testNewSpaceRequestShowsTheCreationView() {
        let model = makeModel()
        XCTAssertFalse(model.spaceFlow.isCreating)
        model.sidebar.requestFromMenu(.newSpace)
        XCTAssertTrue(model.spaceFlow.isCreating)
        XCTAssertEqual(model.spaceFlow.draftName, "")
        XCTAssertNil(model.spaceFlow.draftIcon)
        XCTAssertEqual(model.spaceFlow.draftProfileID, fixture.profile)
        model.stop()
    }

    /// [06 §1] observed: the new Space goes right after the current one, not at the end, and is selected.
    func testNewSpaceGoesAfterTheCurrentSpaceAndIsSelected() throws {
        let model = makeModel(selecting: fixture.home)
        XCTAssertEqual(dockNames(model), ["Home", "Work"])
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Reading"
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(dockNames(model), ["Home", "Reading", "Work"])
        XCTAssertEqual(model.selectedSpaceID, id)
        XCTAssertFalse(model.spaceFlow.isCreating)
        XCTAssertEqual(model.workspace.spaces[id]?.profileID, fixture.profile)
        model.stop()
    }

    /// Creating while the last Space is current appends after it.
    func testNewSpaceAfterTheLastSpaceIsAppended() throws {
        let model = makeModel(selecting: fixture.work)
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Play"
        XCTAssertNotNil(model.spaceFlow.create())
        XCTAssertEqual(dockNames(model), ["Home", "Work", "Play"])
        model.stop()
    }

    /// [06 §1] observed: a new Space gets its own Theme. [07 §8.5] observed: with no color picked
    /// it has no color dots and the light appearance (Arc's lavender-to-pink default).
    func testNewSpaceGetsAThemeWithTheDefaultOrChosenColor() throws {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "A"
        let a = try XCTUnwrap(model.spaceFlow.create())
        let themeA = try XCTUnwrap(model.workspace.spaces[a]?.themeID.flatMap { model.workspace.themes[$0] })
        XCTAssertEqual(themeA.style, SpaceFlowLocalTokens.defaultThemeStyle)
        XCTAssertEqual(themeA.colors, [])
        XCTAssertEqual(themeA.appearance, .light)

        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "B"
        let chosen = ThemePresets.groups[0].colors[2]
        model.spaceFlow.draftTheme.colors = [chosen]
        model.spaceFlow.draftTheme.appearance = .dark
        let b = try XCTUnwrap(model.spaceFlow.create())
        let themeB = try XCTUnwrap(model.workspace.spaces[b]?.themeID.flatMap { model.workspace.themes[$0] })
        XCTAssertEqual(themeB.colors, [chosen])
        XCTAssertEqual(themeB.appearance, .dark)
        XCTAssertNotEqual(themeA.id, themeB.id)
        model.stop()
    }

    /// [06 §1] observed: the dashed "+" button picks an icon for the new Space.
    func testNewSpaceKeepsTheChosenIcon() throws {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Music"
        model.spaceFlow.draftIcon = "🎵"
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(model.workspace.spaces[id]?.icon, "🎵")
        model.stop()
    }

    /// [06 §1] observed: "Cancel" returns to the sidebar and changes nothing.
    func testCancelChangesNothing() {
        let model = makeModel(selecting: fixture.home)
        let before = model.workspace
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Discarded"
        model.spaceFlow.cancelCreate()
        XCTAssertFalse(model.spaceFlow.isCreating)
        XCTAssertEqual(model.workspace, before)
        XCTAssertEqual(model.selectedSpaceID, fixture.home)
        // A stray create after cancel is ignored.
        XCTAssertNil(model.spaceFlow.create())
        XCTAssertEqual(model.workspace, before)
        model.stop()
    }

    /// [06 §1] observed: "Create Space" is disabled while the name is empty. Whitespace-only counts
    /// as empty (inferred) and the stored name is trimmed (inferred).
    func testEmptyNameDisablesCreate() throws {
        let model = makeModel()
        let before = model.workspace
        model.spaceFlow.beginCreate()
        XCTAssertFalse(model.spaceFlow.canCreate)
        XCTAssertNil(model.spaceFlow.create())
        model.spaceFlow.draftName = "   "
        XCTAssertFalse(model.spaceFlow.canCreate)
        XCTAssertNil(model.spaceFlow.create())
        XCTAssertEqual(model.workspace, before)
        XCTAssertTrue(model.spaceFlow.isCreating)

        model.spaceFlow.draftName = "  Trip  "
        XCTAssertTrue(model.spaceFlow.canCreate)
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(model.workspace.spaces[id]?.name, "Trip")
        model.stop()
    }

    /// [06 §1] observed: the form has a Profile picker. A Space in another profile cannot be placed
    /// "after" the current one (the dock order is per profile), so it goes to the end of its profile.
    func testNewSpaceInAnotherProfile() throws {
        let other = SidebarFixture.id(900)
        fixture.ws = TreeOps.createProfile(fixture.ws, id: other, name: "Work profile", now: fixture.now)
        let model = makeModel(selecting: fixture.home)
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Elsewhere"
        model.spaceFlow.draftProfileID = other
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(model.workspace.spaces[id]?.profileID, other)
        XCTAssertEqual(model.selectedSpaceID, id)
        XCTAssertNil(model.spaceFlow.lastError)
        model.stop()
    }

    func testCreateReportsEditsToTheChangeHook() throws {
        let model = makeModel()
        var seen = 0
        model.sidebar.onWorkspaceChange = { _ in seen += 1 }
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Hooked"
        XCTAssertNotNil(model.spaceFlow.create())
        XCTAssertEqual(seen, 1)
        model.stop()
    }

    // MARK: Rename Space [01 §Spaces, 05 §context menus]

    func testRenameSpace() throws {
        let model = makeModel()
        model.sidebar.requestFromMenu(.renameSpace(spaceID: fixture.work))
        XCTAssertEqual(model.spaceFlow.renamingSpaceID, fixture.work)
        XCTAssertEqual(model.spaceFlow.renameText, "Work")
        model.spaceFlow.renameText = "  Office "
        model.spaceFlow.commitRename()
        XCTAssertNil(model.spaceFlow.renamingSpaceID)
        XCTAssertEqual(model.workspace.spaces[fixture.work]?.name, "Office")
        XCTAssertEqual(dockNames(model), ["Home", "Office"])
        model.stop()
    }

    /// Rename stamps only the naming group, so a concurrent dock reorder is not overwritten.
    func testRenameStampsOnlyTheNamingGroup() throws {
        let model = makeModel()
        let before = try XCTUnwrap(model.workspace.spaces[fixture.work])
        clock = later
        model.spaceFlow.beginRename(spaceID: fixture.work)
        model.spaceFlow.renameText = "Office"
        model.spaceFlow.commitRename()
        let after = try XCTUnwrap(model.workspace.spaces[fixture.work])
        let naming = Space.FieldGroup.naming.rawValue
        XCTAssertGreaterThan(after.meta.fieldGroupModifiedAt[naming] ?? .distantPast, before.meta.fieldGroupModifiedAt[naming] ?? .distantPast)
        for group in [Space.FieldGroup.placement, .theme, .profile] {
            XCTAssertEqual(after.meta.fieldGroupModifiedAt[group.rawValue], before.meta.fieldGroupModifiedAt[group.rawValue])
        }
        XCTAssertEqual(after.dockSortKey, before.dockSortKey)
        model.stop()
    }

    func testRenameWithEmptyNameKeepsTheOldName() {
        let model = makeModel()
        model.spaceFlow.beginRename(spaceID: fixture.work)
        model.spaceFlow.renameText = "   "
        model.spaceFlow.commitRename()
        XCTAssertEqual(model.workspace.spaces[fixture.work]?.name, "Work")
        // The sheet stays up so the user can fix the name.
        XCTAssertEqual(model.spaceFlow.renamingSpaceID, fixture.work)
        model.spaceFlow.cancelRename()
        XCTAssertNil(model.spaceFlow.renamingSpaceID)
        model.stop()
    }

    func testCancelRenameChangesNothing() {
        let model = makeModel()
        let before = model.workspace
        model.spaceFlow.beginRename(spaceID: fixture.work)
        model.spaceFlow.renameText = "Nope"
        model.spaceFlow.cancelRename()
        XCTAssertEqual(model.workspace, before)
        model.stop()
    }

    func testRenameOfUnknownSpaceIsIgnored() {
        let model = makeModel()
        model.spaceFlow.beginRename(spaceID: SidebarFixture.id(777))
        XCTAssertNil(model.spaceFlow.renamingSpaceID)
        model.stop()
    }

    // MARK: Change Space Icon [05 §context menus]

    func testChangeSpaceIcon() throws {
        let model = makeModel()
        model.sidebar.requestFromMenu(.changeSpaceIcon(spaceID: fixture.work))
        XCTAssertEqual(model.spaceFlow.iconPickerSpaceID, fixture.work)
        model.spaceFlow.chooseIcon("💼")
        XCTAssertNil(model.spaceFlow.iconPickerSpaceID)
        XCTAssertEqual(model.workspace.spaces[fixture.work]?.icon, "💼")
        XCTAssertEqual(model.workspace.spaces[fixture.work]?.name, "Work")

        model.spaceFlow.beginChangeIcon(spaceID: fixture.work)
        model.spaceFlow.chooseIcon("briefcase")
        XCTAssertEqual(model.workspace.spaces[fixture.work]?.icon, "briefcase")

        model.spaceFlow.beginChangeIcon(spaceID: fixture.work)
        model.spaceFlow.chooseIcon(nil)
        XCTAssertNil(model.workspace.spaces[fixture.work]?.icon)
        model.stop()
    }

    func testCancelChangeIconChangesNothing() {
        let model = makeModel()
        let before = model.workspace
        model.spaceFlow.beginChangeIcon(spaceID: fixture.work)
        model.spaceFlow.cancelChangeIcon()
        XCTAssertEqual(model.workspace, before)
        XCTAssertNil(model.spaceFlow.iconPickerSpaceID)
        model.stop()
    }

    func testEditsReportToTheChangeHook() {
        let model = makeModel()
        var seen = 0
        model.sidebar.onWorkspaceChange = { _ in seen += 1 }
        model.spaceFlow.beginRename(spaceID: fixture.home)
        model.spaceFlow.renameText = "Base"
        model.spaceFlow.commitRename()
        model.spaceFlow.beginChangeIcon(spaceID: fixture.home)
        model.spaceFlow.chooseIcon("🏠")
        XCTAssertEqual(seen, 2)
        model.stop()
    }

    // MARK: Pure edits

    func testSpaceEditsRejectTombstonedSpaces() throws {
        let ws = try TreeOps.deleteSpace(fixture.ws, id: fixture.work, now: later)
        XCTAssertThrowsError(try TreeOps.renameSpace(ws, id: fixture.work, name: "X", now: later))
        XCTAssertThrowsError(try TreeOps.setSpaceIcon(ws, id: fixture.work, icon: "🏠", now: later))
    }
}
