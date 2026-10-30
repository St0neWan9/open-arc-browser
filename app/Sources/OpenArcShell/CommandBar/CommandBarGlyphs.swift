import Foundation

// Glyphs of the command bar: the per-command symbol, the boxed command glyph, the input row's
// leading glyph and the right-hand accessory (shortcut chip or arrow box). Plain values, so the
// rules are unit-testable; the view in `CommandBarView.swift` only draws them.
//
// Spec: docs/arc-spec/07-design-system.md §5 (E27, 2026-10-30) observed:
//   - command rows draw their glyph in a ≈ 20 × 20 rounded box (white + theme-colored glyph when
//     selected, ≈ #F0F0F0 + gray glyph otherwise); search, history and site rows have no box;
//   - the input field's leading glyph follows the first result: that command's glyph when it is a
//     command, the magnifier otherwise;
//   - rows of commands with a shortcut show it in a chip styled like the arrow box, and no arrow box.
// The symbols are SF Symbols we picked ourselves.

extension CommandBarCommand {
    /// SF Symbol of the command's row glyph (also the input glyph while it is the first result).
    /// The one place that maps commands to symbols. [07 §5] E27 observed for the commands in
    /// `observedGlyphs` (shape observed, symbol ours); every other symbol is inferred from the
    /// command's meaning (Arc's were not checked one by one, unknown).
    public var glyphSymbol: String {
        switch self {
        // Observed shapes [07 §5] E27.
        case .contactTheTeam: return "ellipsis.bubble"
        case .openSettings: return "gearshape"
        case .copyURL: return "doc.on.doc"
        case .addSplitView: return "rectangle.split.2x1"
        case .archiveTab, .viewArchive: return "archivebox"
        // Inferred: the other split commands keep the two-pane rectangle, stacked for the
        // top / bottom / vertical ones.
        case .addLeftSplit, .addRightSplit, .convertToHorizontalSplit, .closeSplitPane,
             .separateFromSplit, .expandSplit:
            return "rectangle.split.2x1"
        case .addTopSplit, .addBottomSplit, .convertToVerticalSplit:
            return "rectangle.split.1x2"
        // Inferred from the meaning.
        case .newTab: return "plus"
        case .newWindow: return "macwindow.badge.plus"
        case .newIncognitoWindow: return "eye.slash"
        case .newLittleArcWindow: return "macwindow"
        case .restoreLastClosedTab: return "arrow.uturn.backward"
        case .toggleSidebar: return "sidebar.left"
        case .reload: return "arrow.clockwise"
        case .clearCookiesAndRefresh: return "arrow.clockwise.circle"
        case .newSpace: return "rectangle.stack.badge.plus"
        case .editTheme: return "paintpalette"
        case .renameSpace, .renameCurrentItem: return "pencil"
        case .nextSpace: return "arrow.right.square"
        case .previousSpace: return "arrow.left.square"
        case .manageSpaces: return "square.stack"
        case .togglePin: return "pin"
        case .favoriteTab: return "star"
        case .newFolder: return "folder.badge.plus"
        case .moveToToday: return "tray.and.arrow.down"
        case .replacePinWithCurrentPage: return "arrow.2.squarepath"
        case .resetTabToOriginalURL: return "arrow.counterclockwise"
        case .duplicateTab: return "square.on.square"
        case .nextTab: return "arrow.down"
        case .previousTab: return "arrow.up"
        case .clearToday: return "xmark.circle"
        case .collapseAllFolders: return "rectangle.compress.vertical"
        case .expandAllFolders: return "rectangle.expand.vertical"
        case .goBack: return "arrow.left"
        case .goForward: return "arrow.right"
        case .openLibrary: return "books.vertical"
        case .viewDownloads: return "arrow.down.circle"
        case .viewEasels: return "scribble"
        case .viewMedia: return "photo.on.rectangle"
        case .viewBoosts: return "paintbrush"
        case .airTrafficControl: return "arrow.triangle.branch"
        case .aboutProject: return "info.circle"
        case .organizingTips: return "lightbulb"
        case .helpCenter: return "questionmark.circle"
        }
    }

    /// Commands whose glyph shape was observed in Arc. [07 §5] E27 observed: Contact the Team =
    /// speech bubble with three dots, Settings = gear, Copy URL = two stacked sheets, Add Split
    /// View = two-column box, View Archive… / Archive Tab = archive box.
    public static let observedGlyphs: Set<CommandBarCommand> = [
        .contactTheTeam, .openSettings, .copyURL, .addSplitView, .archiveTab, .viewArchive,
    ]
}

extension CommandBarResult {
    /// The app command the row runs; nil for every other row.
    public var command: CommandBarCommand? {
        if case .runCommand(let command) = action { return command }
        return nil
    }

    /// Whether the row's glyph sits in the rounded glyph box: app command rows only. [07 §5] E27
    /// observed (search, history and site rows draw a bare glyph or favicon); Space rows ("Go to
    /// “…”") stay bare too (inferred, not captured).
    public var drawsGlyphBox: Bool { kind == .command && command != nil }

    /// What the row shows at its right end in a presentation.
    public func trailingAccessory(for presentation: CommandBarPresentation) -> CommandBarRowAccessory {
        if let hint = visibleShortcutHint(for: presentation) {
            return .shortcutChip(hint)
        }
        // [07 §5] E27 follow-up observed (2026-10-30): in the window's bar only open-tab rows draw
        // the arrow box; site, search, history and command rows end bare.
        if presentation == .window, !kind.isTab { return .none }
        return .arrowBox
    }
}

/// The right-hand accessory of a result row: exactly one of the two. [07 §5] E27 observed: a
/// command with a shortcut shows it in a chip and no arrow box; [06 §16.2] observed the hint
/// sitting where the arrow box goes.
public enum CommandBarRowAccessory: Hashable, Sendable {
    /// The shortcut in a small chip: white with theme-colored text when selected, ≈ #F0F0F0 with
    /// gray text otherwise.
    case shortcutChip(String)
    /// The 24 × 24 arrow box.
    case arrowBox
    /// Nothing (rows other than open tabs in the window's bar).
    case none
}
