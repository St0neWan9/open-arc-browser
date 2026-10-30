import Foundation
import Combine
import OpenArcModel
import OpenArcDesign

// Create Space / Rename Space / Change Space Icon. Window-level presentation state plus the
// actions behind the surfaces. All workspace changes go through the pure functions in `TreeOps`,
// and the new value is committed through the sidebar view model to the `WorkspaceController`.

/// Values the spec does not pin down for these flows. Each carries its evidence level.
enum SpaceFlowLocalTokens {
    /// Theme of a new Space when the user picks no color: no color dots, light. [07 §8.5] observed
    /// (2026-10-28): Arc stores no window theme for such a Space and draws its fixed lavender-to-pink
    /// default (`ThemeDerivation.defaultWindowStops`); its theme bubble opens with "Tap to pick a
    /// color for this space" and the light (sun) segment selected.
    static var defaultThemeStyle: ThemeStyle { SpaceThemeDraft().style }

    /// The placeholder color new Spaces got before B98 (a soft blue, never Arc's). A theme whose
    /// only color is this one was never picked by the user and is moved to `defaultThemeStyle`'s
    /// colors at launch (`WorkspaceController.migratePlaceholderThemes`).
    static let legacyPlaceholderColor = RGBAColor(hex: 0x7FA6E8)

    /// Generic emoji for the icon picker. The icon set of Arc is not ours to copy. inferred.
    static let emoji: [String] = [
        "🏠", "💼", "📚", "🎮", "🎵", "🎨", "🛒", "✈️", "🍳", "💡", "🔬", "🧪",
        "📈", "🧠", "🌱", "🔥", "⭐️", "❤️", "🎓", "🏋️", "📷", "🎬", "🛠️", "🧩",
        "🌍", "☕️", "🐶", "🚀", "💬", "📰", "🏦", "🧘",
    ]

    /// SF Symbol names offered next to the emoji. A symbol name is stored as the icon string
    /// (`Space.icon`: "an emoji or an icon name"). inferred.
    static let symbols: [String] = [
        "house", "briefcase", "book", "gamecontroller", "music.note", "paintbrush",
        "cart", "airplane", "leaf", "flame", "star", "heart",
    ]

    // Layout of the creation view. [06 §1] gives the order of the elements, not their sizes.
    static let contentWidth: CGFloat = 220          // unknown
    static let fieldHeight: CGFloat = 36            // unknown (matches the address field height)
    static let iconButtonSize: CGFloat = 28         // unknown
    /// How far the "Choose a Theme" bubble anchor reaches past our 28 pt form inset, so its right
    /// edge sits where Arc's row ends (x 262 of 276). [07 §12] observed row frame.
    static let themeRowAnchorOutset: CGFloat = 14
    /// Side inset of the creation form; the "Create Space" button reaches past it to the sidebar
    /// content edges (`CreateSpaceButtonTokens`, [07 §8.6] observed). Own value.
    static let formHorizontalInset: CGFloat = 28
    static let swatchSize: CGFloat = 20             // unknown
    static let iconSheetSize = Size2D(width: 360, height: 360)     // inferred
}

/// The theme bubble's working copy of a theme's `style` group. Becomes a `Theme` record through
/// `TreeOps.createTheme` / `TreeOps.editSpaceTheme`.
struct SpaceThemeDraft: Equatable {
    /// [07 §8.5] observed: the bubble of a Space with no picked color shows the light segment.
    var appearance: ThemeAppearance = .light
    var colors: [RGBAColor] = []
    var grain: Double = 0
    /// Ring knob value, stored as `Theme.brightness`. [06 §2] inferred ("brightness/contrast").
    var brightness: Double = Theme.defaultBrightness

    /// The model value of the draft.
    var style: ThemeStyle {
        ThemeStyle(appearance: appearance, colors: colors, grain: grain, brightness: brightness)
    }
}

extension SpaceThemeDraft {
    /// The draft that shows an existing theme.
    init(_ style: ThemeStyle) {
        self.init(appearance: style.appearance, colors: style.colors, grain: style.grain, brightness: style.brightness)
    }
}

/// State and actions of the three Space surfaces. Owned by `ShellModel`.
@MainActor
public final class SpaceFlowModel: ObservableObject {
    // MARK: Presentation

    /// The sidebar is replaced by the creation view. [06 §1] observed.
    @Published public private(set) var isCreating = false
    /// Space whose name is being edited (rename sheet).
    @Published public private(set) var renamingSpaceID: UUID?
    /// Space whose icon is being picked (icon sheet).
    @Published public private(set) var iconPickerSpaceID: UUID?
    /// Space whose theme bubble is open (Spaces ▸ Edit Theme… / Edit Theme Color…). [06 §2] observed.
    @Published public private(set) var themeEditorSpaceID: UUID?
    /// Item that Move to ▸ New Space… moves into the Space being created (B77).
    @Published public private(set) var pendingMoveItemID: UUID?
    /// Last rejected operation, for tests and diagnostics.
    @Published public private(set) var lastError: Error?

    // MARK: Create form

    /// "Space name…" field. [06 §1] observed.
    @Published public var draftName = ""
    /// Icon chosen with the dashed "+" button; nil = default icon.
    @Published public var draftIcon: String?
    /// "Profile [Default ▾]". Defaults to the current Space's profile. inferred.
    @Published public var draftProfileID: UUID?
    @Published var draftTheme = SpaceThemeDraft()
    /// Text of the rename field.
    @Published public var renameText = ""

    private let sidebar: SidebarViewModel
    private let now: () -> Date
    private let makeID: () -> UUID

    init(sidebar: SidebarViewModel, now: @escaping () -> Date, makeID: @escaping () -> UUID) {
        self.sidebar = sidebar
        self.now = now
        self.makeID = makeID
    }

    // MARK: Create Space

    /// Create button is disabled while the name is empty. [06 §1] observed. Whitespace-only
    /// counts as empty. inferred.
    public var canCreate: Bool {
        !trimmed(draftName).isEmpty && draftProfileID.flatMap { sidebar.workspace.profiles[$0] }.map { !$0.meta.isTombstone } == true
    }

    /// Profiles offered by the Profile picker.
    var profiles: [Profile] {
        sidebar.workspace.profiles.values.filter { !$0.meta.isTombstone }.sorted { $0.name < $1.name }
    }

    /// Spaces ▸ New Space… / the dock "+" button: shows the creation view with a fresh form.
    /// `moving` (Move to ▸ New Space…, [06 §21.5] observed item, B77) names a tab, folder or split
    /// layout that moves into the Space once it is created; Cancel leaves it where it is.
    public func beginCreate(moving itemID: UUID? = nil) {
        draftName = ""
        draftIcon = nil
        draftTheme = SpaceThemeDraft()
        draftProfileID = sidebar.currentProfileID
        renamingSpaceID = nil
        iconPickerSpaceID = nil
        pendingMoveItemID = itemID
        isCreating = true
    }

    /// "Cancel": back to the sidebar, nothing changed. [06 §1] observed.
    public func cancelCreate() {
        pendingMoveItemID = nil
        isCreating = false
    }

    /// "Create Space": adds the Space (and its Theme) right after the current Space, selects it
    /// and returns to the sidebar. [06 §1] observed. Returns nil when the form is not valid.
    @discardableResult
    public func create() -> UUID? {
        guard isCreating, canCreate, let profileID = draftProfileID else { return nil }
        let spaceID = makeID(), themeID = makeID()
        // The dock order is kept per profile, so "after the current Space" only applies when the
        // new Space joins the current Space's profile; otherwise it goes to the end of its profile.
        let current = sidebar.selectedSpace
        let anchor = current.flatMap { sidebar.workspace.localProfileID(for: $0.profileID) } == profileID ? current?.id : nil
        let name = trimmed(draftName), icon = draftIcon, theme = draftTheme, stamp = now()
        guard commit({
            // The Space and its Theme are added in one step. [06 §1] observed: inserted after the current Space.
            try TreeOps.createSpace(
                TreeOps.createTheme($0, id: themeID, style: theme.style, now: stamp),
                id: spaceID, profileID: profileID, name: name, icon: icon,
                themeID: themeID, afterSpaceID: anchor, now: stamp
            )
        }) else { return nil }
        isCreating = false
        // Move to ▸ New Space…: the item goes into the new Space before the sidebar shows it, so a
        // moved selected tab stays selected there (inferred).
        if let item = pendingMoveItemID {
            pendingMoveItemID = nil
            sidebar.moveItem(item, toSpace: spaceID)
        }
        sidebar.selectSpace(spaceID)
        return spaceID
    }

    // MARK: Rename Space

    /// Spaces ▸ Rename Space / Space menu ▸ Rename Space…: opens the rename sheet.
    public func beginRename(spaceID: UUID) {
        guard let space = liveSpace(spaceID) else { return }
        renameText = space.name
        renamingSpaceID = spaceID
    }

    public func cancelRename() { renamingSpaceID = nil }

    /// Applies the new name. An empty name is rejected and the old name stays. inferred (the
    /// spec only shows the create form disabling an empty name).
    public func commitRename() {
        guard let id = renamingSpaceID else { return }
        let name = trimmed(renameText)
        guard !name.isEmpty else { return }
        renamingSpaceID = nil
        guard liveSpace(id)?.name != name else { return }
        let stamp = now()
        commit { try TreeOps.renameSpace($0, id: id, name: name, now: stamp) }
    }

    // MARK: Change Space Icon

    public func beginChangeIcon(spaceID: UUID) {
        guard liveSpace(spaceID) != nil else { return }
        iconPickerSpaceID = spaceID
    }

    public func cancelChangeIcon() { iconPickerSpaceID = nil }

    /// Applies an icon and closes the picker; nil resets to the default icon.
    public func chooseIcon(_ icon: String?) {
        guard let id = iconPickerSpaceID else { return }
        iconPickerSpaceID = nil
        guard liveSpace(id)?.icon != icon else { return }
        let stamp = now()
        commit { try TreeOps.setSpaceIcon($0, id: id, icon: icon, now: stamp) }
    }

    // MARK: Edit Theme

    /// Opens the theme bubble for an existing Space. Not available while the creation view is up,
    /// which has its own "Choose a Theme" bubble. [06 §2] observed.
    public func beginEditTheme(spaceID: UUID) {
        guard !isCreating, liveSpace(spaceID) != nil else { return }
        themeEditorSpaceID = spaceID
    }

    /// Closes the bubble. Edits were applied live, so there is nothing to commit or roll back.
    /// inferred: the spec shows no Apply or Cancel button in the bubble.
    public func closeThemeEditor() { themeEditorSpaceID = nil }

    /// The editor's view of a Space's theme. A Space without a theme has no color points.
    func themeDraft(of spaceID: UUID) -> SpaceThemeDraft {
        guard let themeID = liveSpace(spaceID)?.themeID, let theme = sidebar.workspace.themes[themeID],
              !theme.meta.isTombstone
        else { return SpaceThemeDraft() }
        return SpaceThemeDraft(theme.style)
    }

    /// Applies the editor's draft to the Space immediately (live preview). inferred: Arc applies edits as they happen.
    /// Only `Theme.style` is stamped; a Space without a live theme gets a new one (`Space.theme` stamped).
    /// An unchanged draft leaves the workspace untouched.
    func applyThemeDraft(_ draft: SpaceThemeDraft, to spaceID: UUID) {
        let stamp = now(), newThemeID = makeID()
        commit { try TreeOps.editSpaceTheme($0, spaceID: spaceID, newThemeID: newThemeID, style: draft.style, now: stamp) }
    }

    /// The system light/dark setting, for theme drafts set to Automatic (B21).
    var systemAppearance: ResolvedAppearance { sidebar.controller.systemAppearance }

    // MARK: Internals

    private func liveSpace(_ id: UUID) -> Space? {
        sidebar.workspace.spaces[id].flatMap { $0.meta.isTombstone ? nil : $0 }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Commits the new workspace through the sidebar to the app's `WorkspaceController` (the single
    /// owner), which saves it and updates every window.
    @discardableResult
    private func commit(_ transform: (WorkspaceState) throws -> WorkspaceState) -> Bool {
        do {
            let new = try transform(sidebar.workspace)
            sidebar.commitWorkspace(new)
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }
}
