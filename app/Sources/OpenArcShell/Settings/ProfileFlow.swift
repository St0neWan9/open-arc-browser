import SwiftUI
import Combine
import OpenArcModel
import OpenArcDesign

// File ▸ New Profile and Spaces ▸ Change Profile (plan B72). [06 §16.3] observed (by the way of
// the profile deletion capture): Spaces ▸ Change Profile shows a "Change <Space>'s Profile" form
// (an explanation and a Profile pop-up whose last entry is "New Profile"); a new profile is made
// in three steps: a name ("Profiles are not synced between computers."), which Spaces use it
// (each Space with its icon, the current one checked), then a confirmation that cannot be undone.
// The wording below is ours; the steps and their order follow the capture. Profiles stay on this
// Mac (plan Q13, B73).

/// Values the spec does not give. Each carries its evidence level.
enum ProfileFlowTokens {
    /// Sheet size. [06 §16.3] observed only for the Delete sheet (≈ 450 × 349); the width is
    /// shared, the heights are ours (inferred).
    static let sheetWidth: Double = 450
    static let nameStepHeight: Double = 300
    static let spacesStepHeight: Double = 360
    static let confirmStepHeight: Double = 250
    static let changeSheetHeight: Double = 280
    /// The icon button left of the name field (same as the Create Space form, inferred).
    static let iconButtonSize: CGFloat = 37.5
    static let iconPickerSize = CGSize(width: 320, height: 300)
    /// Title of the pop-up entry that starts a new profile. [06 §16.3] observed.
    static let newProfileEntry = "New Profile"
    /// The footnote under the name field (our wording of the observed line, B73 / plan Q13).
    static let notSyncedNote = "Profiles stay on this Mac. They are not synced to your other computers."
}

/// State and actions of the profile sheets of one window. Workspace changes go through `TreeOps`
/// on the app's `WorkspaceController`.
@MainActor
public final class ProfileFlowModel: ObservableObject {
    /// The steps of New Profile. [06 §16.3] observed order.
    public enum Step: Equatable, Sendable {
        case name
        case spaces
        case confirm
    }

    /// The New Profile sheet is showing at this step; nil when it is not.
    @Published public private(set) var newProfileStep: Step?
    /// The Space whose Change Profile sheet is showing.
    @Published public private(set) var changingSpaceID: UUID?

    // MARK: New Profile draft
    @Published public var draftName = ""
    /// Emoji or icon name; nil is the default icon.
    @Published public var draftIcon: String?
    /// Spaces that will use the new profile.
    @Published public var draftSpaceIDs: Set<UUID> = []

    // MARK: Change Profile draft
    /// The profile chosen in the Change Profile pop-up.
    @Published public var chosenProfileID: UUID?

    /// The last rejected operation, for tests and diagnostics.
    @Published public private(set) var lastError: Error?

    private let sidebar: SidebarViewModel
    /// The Change Profile sheet that led to New Profile, to return to on Cancel (inferred).
    private var returnToChangeSpaceID: UUID?

    init(sidebar: SidebarViewModel) {
        self.sidebar = sidebar
    }

    private var workspace: WorkspaceState { sidebar.workspace }

    /// Live profiles, oldest (Default) first.
    var profiles: [Profile] { workspace.liveProfilesOldestFirst }

    /// Spaces offered in the "which Spaces" step, in dock order.
    var spaces: [Space] { sidebar.dockSpaces }

    // MARK: New Profile

    /// File ▸ New Profile: the name step, with the window's Space checked for the next step
    /// ([06 §16.3] observed: "the current Space is checked by default").
    public func beginNewProfile(forSpace spaceID: UUID? = nil) {
        guard !sidebar.isIncognito else { return }
        changingSpaceID = nil
        draftName = ""
        draftIcon = nil
        draftSpaceIDs = Set([spaceID ?? sidebar.selectedSpaceID].compactMap { $0 })
        newProfileStep = .name
    }

    var canContinueFromName: Bool { !trimmed(draftName).isEmpty }

    /// Continue: name → Spaces → confirmation. The confirmation is skipped when no Space moves
    /// (nothing to undo then, inferred), and the profile is made right away.
    public func next() {
        switch newProfileStep {
        case .name?:
            guard canContinueFromName else { return }
            newProfileStep = .spaces
        case .spaces?:
            if draftSpaceIDs.isEmpty { createProfile() } else { newProfileStep = .confirm }
        case .confirm?:
            createProfile()
        case nil:
            break
        }
    }

    /// Back one step; from the name step it closes the sheet.
    public func back() {
        switch newProfileStep {
        case .confirm?: newProfileStep = .spaces
        case .spaces?: newProfileStep = .name
        case .name?, nil: cancelNewProfile()
        }
    }

    /// Cancel: nothing changes. A New Profile started from Change Profile goes back to it.
    public func cancelNewProfile() {
        newProfileStep = nil
        if let spaceID = returnToChangeSpaceID {
            returnToChangeSpaceID = nil
            beginChangeProfile(spaceID: spaceID)
        }
    }

    public func toggleDraftSpace(_ spaceID: UUID) {
        if draftSpaceIDs.contains(spaceID) { draftSpaceIDs.remove(spaceID) } else { draftSpaceIDs.insert(spaceID) }
    }

    /// Creates the profile and moves the chosen Spaces to it, in one workspace change. Returns the
    /// new profile id, nil when refused.
    @discardableResult
    public func createProfile() -> UUID? {
        let name = trimmed(draftName)
        guard !name.isEmpty else { return nil }
        let controller = sidebar.controller
        let id = controller.makeID(), stamp = controller.now()
        let icon = draftIcon
        let moved = spaces.map(\.id).filter(draftSpaceIDs.contains)
        do {
            try controller.mutate(origin: sidebar) { state in
                try moved.reduce(TreeOps.createProfile(state, id: id, name: name, icon: icon, now: stamp)) {
                    try TreeOps.setSpaceProfile($0, id: $1, profileID: id, now: stamp)
                }
            }
        } catch {
            lastError = error
            return nil
        }
        lastError = nil
        newProfileStep = nil
        returnToChangeSpaceID = nil
        return id
    }

    // MARK: Change Profile

    /// Spaces ▸ Change Profile: the sheet for `spaceID`, its current profile chosen.
    public func beginChangeProfile(spaceID: UUID) {
        guard !sidebar.isIncognito, let space = workspace.spaces[spaceID], !space.meta.isTombstone else { return }
        newProfileStep = nil
        chosenProfileID = workspace.localProfileID(for: space.profileID)
        changingSpaceID = spaceID
    }

    public func cancelChangeProfile() { changingSpaceID = nil }

    /// The pop-up's "New Profile" entry: the New Profile sheet for this Space; Cancel there returns
    /// here (inferred).
    public func chooseNewProfileFromChange() {
        guard let spaceID = changingSpaceID else { return }
        beginNewProfile(forSpace: spaceID)
        returnToChangeSpaceID = spaceID
    }

    /// Applies the chosen profile to the Space.
    public func applyChangeProfile() {
        guard let spaceID = changingSpaceID, let profileID = chosenProfileID else { return }
        changingSpaceID = nil
        let controller = sidebar.controller
        let stamp = controller.now()
        do {
            try controller.mutate(origin: sidebar) { try TreeOps.setSpaceProfile($0, id: spaceID, profileID: profileID, now: stamp) }
            lastError = nil
        } catch {
            lastError = error
        }
    }

    var changingSpaceName: String { changingSpaceID.flatMap { workspace.spaces[$0]?.name } ?? "" }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Views

/// Presents the profile sheets on the window content.
struct ProfileFlowSheets: ViewModifier {
    @ObservedObject var flow: ProfileFlowModel
    let palette: ThemePalette

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { flow.newProfileStep != nil },
                set: { if !$0 { flow.cancelNewProfile() } }
            )) { NewProfileSheet(flow: flow, palette: palette) }
            .sheet(isPresented: Binding(
                get: { flow.changingSpaceID != nil },
                set: { if !$0 { flow.cancelChangeProfile() } }
            )) { ChangeProfileSheet(flow: flow, palette: palette) }
    }
}

/// The three New Profile steps in the Arc sheet style (`ModalCard`).
struct NewProfileSheet: View {
    @ObservedObject var flow: ProfileFlowModel
    let palette: ThemePalette
    @State private var isIconPickerShown = false

    private typealias T = ProfileFlowTokens

    var body: some View {
        switch flow.newProfileStep ?? .name {
        case .name: nameStep
        case .spaces: spacesStep
        case .confirm: confirmStep
        }
    }

    private var nameStep: some View {
        ModalCard(size: Size2D(width: T.sheetWidth, height: T.nameStepHeight), palette: palette) {
            title("Create a new Profile")
            paragraph("A Profile keeps its own history, logins, cookies and extensions. Give it a name and an icon.")
            HStack(spacing: 8) {
                Button { isIconPickerShown = true } label: {
                    Group {
                        if let icon = flow.draftIcon {
                            SpaceIconGlyph(icon: icon, size: 20, tint: palette.dialogInk.swiftUI)
                        } else {
                            Image(systemName: "face.smiling").font(.system(size: 16))
                        }
                    }
                    .frame(width: T.iconButtonSize, height: T.iconButtonSize)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.dialogInk.swiftUI.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.dialogInk.swiftUI.opacity(0.7))
                .accessibilityLabel("Profile Icon")
                .popover(isPresented: $isIconPickerShown) {
                    SpaceIconGrid(showsReset: flow.draftIcon != nil) { icon in
                        flow.draftIcon = icon
                        isIconPickerShown = false
                    }
                    .frame(width: T.iconPickerSize.width)
                }
                ModalCardTextField(placeholder: "Profile name…", text: $flow.draftName, palette: palette,
                                   identifier: "openarc.newProfile.nameField") { flow.next() }
            }
            .padding(.top, ModalCardTokens.fieldGap)
            Text(T.notSyncedNote)
                .font(Typography.settingsCaption.font)
                .foregroundStyle(palette.dialogInk.swiftUI.opacity(0.55))
                .padding(.top, 10)
                .accessibilityIdentifier("openarc.newProfile.notSynced")
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) { flow.cancelNewProfile() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Next", keyCap: "↵", role: .primary, palette: palette, isEnabled: flow.canContinueFromName) { flow.next() }
                    .keyboardShortcut(.defaultAction)
            })
        }
    }

    private var spacesStep: some View {
        ModalCard(size: Size2D(width: T.sheetWidth, height: T.spacesStepHeight), palette: palette) {
            title("Which Spaces should use this Profile?")
            paragraph("Checked Spaces switch to “\(flow.draftName.trimmingCharacters(in: .whitespaces))”. You can change this later from Spaces ▸ Change Profile.")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(flow.spaces, id: \.id) { space in
                        Toggle(isOn: Binding(get: { flow.draftSpaceIDs.contains(space.id) }, set: { _ in flow.toggleDraftSpace(space.id) })) {
                            HStack(spacing: 6) {
                                if let icon = space.icon { SpaceIconGlyph(icon: icon, size: 16, tint: palette.dialogInk.swiftUI) }
                                Text(space.name).foregroundStyle(palette.dialogInk.swiftUI)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(.top, 12)
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Back", keyCap: "ESC", role: .cancel, palette: palette) { flow.back() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: flow.draftSpaceIDs.isEmpty ? "Create" : "Next", keyCap: "↵", role: .primary, palette: palette) { flow.next() }
                    .keyboardShortcut(.defaultAction)
            })
        }
    }

    private var confirmStep: some View {
        let name = flow.draftName.trimmingCharacters(in: .whitespaces)
        let count = flow.draftSpaceIDs.count
        return ModalCard(size: Size2D(width: T.sheetWidth, height: T.confirmStepHeight), palette: palette) {
            title("Use “\(name)” for \(count == 1 ? "this Space" : "\(count) Spaces")?")
            paragraph("Their tabs switch to the new Profile’s logins, cookies and history. You cannot undo this step.")
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Back", keyCap: "ESC", role: .cancel, palette: palette) { flow.back() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Create", keyCap: "↵", role: .primary, palette: palette) { flow.next() }
                    .keyboardShortcut(.defaultAction)
            })
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
            .padding(.top, ModalCardTokens.titleTop)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Typography.settingsBody.font)
            .foregroundStyle(palette.dialogInk.swiftUI.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// "Change <Space>'s Profile": an explanation and a Profile pop-up ending in "New Profile".
/// [06 §16.3] observed; the explanation is ours.
struct ChangeProfileSheet: View {
    @ObservedObject var flow: ProfileFlowModel
    let palette: ThemePalette

    /// The pop-up's tag for its "New Profile" entry.
    private static let newProfileTag = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var body: some View {
        ModalCard(size: Size2D(width: ProfileFlowTokens.sheetWidth, height: ProfileFlowTokens.changeSheetHeight), palette: palette) {
            Text("Change \(flow.changingSpaceName)’s Profile")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .padding(.top, ModalCardTokens.titleTop)
            Text("The Space will use the Profile’s logins, cookies, history and extensions, and show its Favorites at the top of the sidebar.")
                .font(Typography.settingsBody.font)
                .foregroundStyle(palette.dialogInk.swiftUI.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Picker("Profile", selection: Binding(
                get: { flow.chosenProfileID ?? Self.newProfileTag },
                set: { if $0 == Self.newProfileTag { flow.chooseNewProfileFromChange() } else { flow.chosenProfileID = $0 } }
            )) {
                ForEach(flow.profiles, id: \.id) { profile in
                    Text(profile.name).tag(profile.id)
                }
                Divider()
                Text(ProfileFlowTokens.newProfileEntry).tag(Self.newProfileTag)
            }
            .pickerStyle(.menu)
            .frame(width: 260)
            .padding(.top, ModalCardTokens.fieldGap)
            .accessibilityIdentifier("openarc.changeProfile.picker")
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) { flow.cancelChangeProfile() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Change", keyCap: "↵", role: .primary, palette: palette, isEnabled: flow.chosenProfileID != nil) {
                    flow.applyChangeProfile()
                }
                .keyboardShortcut(.defaultAction)
            })
        }
    }
}
