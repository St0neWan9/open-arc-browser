import Foundation
import OpenArcModel
import OpenArcDesign

// "Open in <Space> ⌘O" of the expanded Little Arc window (B60). No UI framework types, so the
// rules are unit-testable.
//
// Spec sources (docs/arc-spec/):
//   [06 §21.7] observed (E19): the top bar shows a Profile capsule (smiley + profile name; seen for
//              a non-Default profile), the centered domain, a copy link icon and a dark button
//              "Open in <Space> ⌘O" (Space name bold, ⌘O as a key cap), a vertical divider and a
//              dropdown arrow. The arrow opens a dark panel in place (over the button, top-right
//              aligned): a "Search Spaces…" field with a collapse arrow, then one row per Space
//              (theme-colored square icon + name, ≈ 39 pt rows), the default target first and
//              highlighted, scrollable. Choosing a Space, or ⌘O, closes Little Arc; the page becomes
//              the selected top Today tab of that Space and the main window switches to it.
//   [06 §25.1] observed: the Settings ▸ Links illustration shows the same bar ("Work" capsule,
//              domain, "Open in Work ⌘O").
//   [02]     observed: ⌘O "Open Little Arc or Peek in…".
//
// Decisions without evidence (inferred):
//   - The default target is the main window's current Space (else the first live Space).
//   - The Profile capsule is shown only for a non-Default profile (Default was not captured).
//   - The search matches Space names case-insensitively, anywhere in the name.

/// One row of the Spaces dropdown.
struct LittleArcSpaceOption: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String?
    /// Color of the square icon: the theme's first color, or the default base. [06 §21.7] observed
    /// "theme-colored square"; which theme color is inferred.
    let swatch: RGBAColor
    /// The button's current target (listed first, highlighted when nothing else is).
    let isDefault: Bool
}

/// State of the Spaces dropdown.
struct LittleArcSpacePickerState: Equatable {
    var isOpen = false
    var query = ""
    /// Index into the filtered options; 0 is the first row (the default target when it matches).
    var highlightedIndex = 0
}

/// Strings and sizes of the "Open in" control. Evidence levels as in CLAUDE.md.
enum LittleArcSpaceTargetTokens {
    /// Button prefix before the bold Space name. [06 §21.7] observed.
    static let openInPrefix = "Open in "
    /// Key cap after the title. [06 §21.7] observed.
    static let keyCap = "⌘O"
    /// Placeholder of the dropdown's field. [06 §21.7] observed.
    static let searchPlaceholder = "Search Spaces…"
    /// Row height of the dropdown. [06 §21.7] observed (≈ 39).
    static let rowHeight: Double = 39
    /// Rows visible before the list scrolls. unknown; inferred.
    static let visibleRows = 6
    /// Width of the dropdown panel. unknown; inferred.
    static let panelWidth: Double = 260
    /// Height of the button. unknown; inferred (text area 147×17 observed).
    static let buttonHeight: Double = 28
    /// Dark fill of the button and panel. [06 §21.7] observed "dark"; value inferred.
    static let darkFill = RGBAColor(hex: 0x232326)
}

enum LittleArcSpaceTarget {
    /// The default target: `selected` when it is a live Space, else the first live Space in dock order.
    static func defaultSpaceID(in workspace: WorkspaceState, selected: UUID?) -> UUID? {
        if let selected, let space = workspace.spaces[selected], !space.meta.isTombstone { return selected }
        return workspace.allLiveSpaces.first?.id
    }

    /// Dropdown rows: the default target first, then the other live Spaces in dock order, keeping
    /// those whose name contains `query` (case-insensitive; an empty query keeps all).
    static func options(in workspace: WorkspaceState, defaultSpaceID: UUID?, query: String) -> [LittleArcSpaceOption] {
        let spaces = workspace.allLiveSpaces
        let ordered = spaces.filter { $0.id == defaultSpaceID } + spaces.filter { $0.id != defaultSpaceID }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ordered
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
            .map { space in
                let theme = space.themeID.flatMap { workspace.themes[$0] }.flatMap { $0.meta.isTombstone ? nil : $0 }
                return LittleArcSpaceOption(
                    id: space.id, name: space.name, icon: space.icon,
                    swatch: theme?.colors.first ?? ThemeDerivation.defaultBaseColor,
                    isDefault: space.id == defaultSpaceID
                )
            }
    }

    /// Name for the Profile capsule: nil for the Default profile or an unknown one (inferred).
    static func profileCapsuleName(in workspace: WorkspaceState, profileID: UUID?) -> String? {
        guard let profileID, profileID != workspace.defaultProfileID,
              let profile = workspace.profiles[profileID], !profile.meta.isTombstone else { return nil }
        return profile.name
    }
}

// MARK: - Model

extension LittleArcModel {
    /// The Space "Open in" names and ⌘O uses. [06 §21.7] observed; the rule is inferred.
    var targetSpaceID: UUID? {
        LittleArcSpaceTarget.defaultSpaceID(in: shell.workspace, selected: shell.selectedSpaceID)
    }

    /// Name shown bold in the button; nil with no live Space (the button then reads
    /// `LittleArcTokens.adoptButtonTitle`).
    var targetSpaceName: String? {
        targetSpaceID.flatMap { shell.workspace.spaces[$0]?.name }
    }

    /// The whole button title, "Open in <Space>". [06 §21.7] observed.
    var adoptButtonTitle: String {
        targetSpaceName.map { LittleArcSpaceTargetTokens.openInPrefix + $0 } ?? LittleArcTokens.adoptButtonTitle
    }

    /// Profile capsule text. [06 §21.7] observed for a non-Default profile.
    var profileCapsuleName: String? {
        LittleArcSpaceTarget.profileCapsuleName(in: shell.workspace, profileID: pageProfileID)
    }

    /// Rows of the open dropdown, filtered by its field.
    var spaceOptions: [LittleArcSpaceOption] {
        LittleArcSpaceTarget.options(in: shell.workspace, defaultSpaceID: targetSpaceID, query: spacePicker.query)
    }

    /// The dropdown arrow: opens the panel with an empty field and the first row highlighted, or
    /// closes it. Only while a page is shown.
    func toggleSpacePicker() {
        if spacePicker.isOpen {
            closeSpacePicker()
        } else if phase == .expanded {
            spacePicker = LittleArcSpacePickerState(isOpen: true)
        }
    }

    func closeSpacePicker() {
        spacePicker = LittleArcSpacePickerState()
    }

    /// Typing in "Search Spaces…" filters the rows and highlights the first match.
    func setSpaceQuery(_ query: String) {
        guard spacePicker.isOpen, spacePicker.query != query else { return }
        spacePicker.query = query
        spacePicker.highlightedIndex = 0
    }

    /// ↑ / ↓ in the dropdown, clamped to the rows. inferred.
    func moveSpaceHighlight(by delta: Int) {
        let count = spaceOptions.count
        guard spacePicker.isOpen, count > 0 else { return }
        spacePicker.highlightedIndex = min(max(spacePicker.highlightedIndex + delta, 0), count - 1)
    }

    /// The highlighted row's Space, if any row matches.
    var highlightedSpaceID: UUID? {
        let options = spaceOptions
        guard options.indices.contains(spacePicker.highlightedIndex) else { return nil }
        return options[spacePicker.highlightedIndex].id
    }

    /// A row was clicked: moves the page into that Space and closes Little Arc. [06 §21.7] observed.
    @discardableResult
    func chooseSpace(_ spaceID: UUID) -> UUID? {
        adopt(into: spaceID)
    }

    /// Return in the dropdown: the highlighted row. inferred.
    @discardableResult
    func chooseHighlightedSpace() -> UUID? {
        guard let spaceID = highlightedSpaceID else { return nil }
        return chooseSpace(spaceID)
    }

    /// The copy link icon: copies the full URL. [06 §21.7] observed (icon); same action as the
    /// main toolbar's copy link [06 §17.3] observed. Returns whether anything was copied.
    @discardableResult
    func copyLink() -> Bool {
        guard phase == .expanded, let url = currentURL else { return false }
        shell.siteControls.pasteboard.writeURL(url)
        return true
    }
}
