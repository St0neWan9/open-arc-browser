import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// File ▸ New Profile and Spaces ▸ Change Profile (plan B72). Spec: docs/arc-spec/06-flows.md
/// §16.3 (observed): Change Profile shows "Change <Space>'s Profile" with a Profile pop-up ending in
/// "New Profile"; New Profile is name ("Profiles are not synced between computers.") → which
/// Spaces (current one checked) → confirmation. 01 §File / §Spaces observed items.
@MainActor
final class ProfileFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private var models: [ShellModel] = []

    override func tearDown() async throws {
        for model in models { model.stop() }
        models = []
    }

    private func makeModel() -> ShellModel {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 100) })
        models.append(model)
        return model
    }

    /// Adds a second Space after the demo's and returns its id.
    private func addSpace(_ model: ShellModel, name: String) throws -> UUID {
        let id = UUID()
        let profile = try XCTUnwrap(model.selectedSpace?.profileID)
        model.sidebar.replaceWorkspace(try TreeOps.createSpace(model.workspace, id: id, profileID: profile, name: name, icon: "briefcase",
                                                               afterSpaceID: model.selectedSpaceID, now: t0))
        return id
    }

    /// 06 §16.3: name → Spaces (the current Space checked) → confirmation → the profile exists and
    /// the checked Spaces use it.
    func testNewProfileStepsAndResult() throws {
        let model = makeModel()
        let flow = model.profileFlow
        let home = try XCTUnwrap(model.selectedSpaceID)
        let work = try addSpace(model, name: "Work")
        flow.beginNewProfile()
        XCTAssertEqual(flow.newProfileStep, .name)
        XCTAssertEqual(flow.draftSpaceIDs, [home], "the current Space is checked")
        flow.next()
        XCTAssertEqual(flow.newProfileStep, .name, "a name is required")
        flow.draftName = "  Side  "
        flow.draftIcon = "🦊"
        flow.next()
        XCTAssertEqual(flow.newProfileStep, .spaces)
        flow.toggleDraftSpace(work)
        flow.next()
        XCTAssertEqual(flow.newProfileStep, .confirm)
        flow.next()
        XCTAssertNil(flow.newProfileStep)
        let created = try XCTUnwrap(model.workspace.liveProfilesOldestFirst.last)
        XCTAssertEqual(created.name, "Side")
        XCTAssertEqual(created.icon, "🦊")
        XCTAssertEqual(model.workspace.spaces[home]?.profileID, created.id)
        XCTAssertEqual(model.workspace.spaces[work]?.profileID, created.id)
    }

    /// No Space checked: Create makes the profile without a confirmation; Back / Cancel change nothing.
    func testNewProfileWithoutSpacesAndCancel() throws {
        let model = makeModel()
        let flow = model.profileFlow
        let before = model.workspace.liveProfilesOldestFirst.count
        flow.beginNewProfile()
        flow.draftName = "Empty"
        flow.next()
        flow.back()
        XCTAssertEqual(flow.newProfileStep, .name)
        flow.cancelNewProfile()
        XCTAssertNil(flow.newProfileStep)
        XCTAssertEqual(model.workspace.liveProfilesOldestFirst.count, before)

        flow.beginNewProfile()
        flow.draftName = "Empty"
        flow.next()
        flow.draftSpaceIDs = []
        flow.next()
        XCTAssertNil(flow.newProfileStep)
        XCTAssertEqual(model.workspace.liveProfilesOldestFirst.count, before + 1)
        XCTAssertEqual(model.workspace.liveProfilesOldestFirst.first.map { model.workspace.spaces(inProfile: $0.id).count }, 1)
    }

    /// The name step carries the not-synced note (B73: profiles stay on this Mac).
    func testNotSyncedNote() {
        XCTAssertTrue(ProfileFlowTokens.notSyncedNote.contains("not synced"))
    }

    /// 06 §16.3: Change Profile for the current Space; its pop-up's New Profile entry opens New
    /// Profile for that Space, and Cancel there comes back.
    func testChangeProfile() throws {
        let model = makeModel()
        let flow = model.profileFlow
        let home = try XCTUnwrap(model.selectedSpaceID)
        let defaultProfile = try XCTUnwrap(model.workspace.defaultProfileID)
        let other = model.sidebar.createProfile(name: "Other")
        model.changeProfileOfCurrentSpace()
        XCTAssertEqual(flow.changingSpaceID, home)
        XCTAssertEqual(flow.chosenProfileID, defaultProfile)
        flow.chooseNewProfileFromChange()
        XCTAssertNil(flow.changingSpaceID)
        XCTAssertEqual(flow.newProfileStep, .name)
        XCTAssertEqual(flow.draftSpaceIDs, [home])
        flow.cancelNewProfile()
        XCTAssertEqual(flow.changingSpaceID, home, "back to Change Profile")
        flow.chosenProfileID = other
        flow.applyChangeProfile()
        XCTAssertNil(flow.changingSpaceID)
        XCTAssertEqual(model.workspace.spaces[home]?.profileID, other)
    }

    /// 06 §20.2 observed: an incognito window has no Change Profile; no profile sheets there.
    func testIncognitoHasNoProfileSheets() throws {
        let controller = WorkspaceController(dependencies: .fake(), workspace: .demo(now: t0))
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        models.append(incognito)
        incognito.profileFlow.beginNewProfile()
        XCTAssertNil(incognito.profileFlow.newProfileStep)
        controller.stop()
    }

    /// The Space menu's Set Profile ▸ New Profile… opens the sheet with that Space checked.
    func testSpaceMenuNewProfileRequest() throws {
        let model = makeModel()
        let work = try addSpace(model, name: "Work")
        model.handle(.newProfile(spaceID: work))
        XCTAssertEqual(model.profileFlow.newProfileStep, .name)
        XCTAssertEqual(model.profileFlow.draftSpaceIDs, [work])
    }
}
