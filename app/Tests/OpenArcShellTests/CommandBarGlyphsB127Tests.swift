import XCTest
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Plan B127: command bar E27 fixes and the drag handle on blank pages.
/// Spec: docs/arc-spec/07-design-system.md §5 (E27 bullet, observed) and 06-flows.md §13 (E27,
/// observed).
final class CommandBarGlyphsB127Tests: XCTestCase {
    private func commandRow(_ command: CommandBarCommand) -> CommandBarResult {
        CommandBarResult(id: "command:\(command.rawValue)", kind: .command, title: command.title,
                         iconHint: .command, actionLabel: nil, action: .runCommand(command),
                         shortcutHint: command.shortcutHint)
    }

    private let searchRow = CommandBarResult(id: "web-search", kind: .webSearch, title: "settings",
                                             iconHint: .search, actionLabel: "Search",
                                             action: .searchWeb(query: "settings", target: .newTab))

    // MARK: [07 §5] E27 per-command glyphs

    /// [07 §5] E27 observed shapes: bubble with dots, gear, two sheets, two columns, archive box.
    func testObservedCommandGlyphs() {
        XCTAssertEqual(CommandBarCommand.contactTheTeam.glyphSymbol, "ellipsis.bubble")
        XCTAssertEqual(CommandBarCommand.openSettings.glyphSymbol, "gearshape")
        XCTAssertEqual(CommandBarCommand.copyURL.glyphSymbol, "doc.on.doc")
        XCTAssertEqual(CommandBarCommand.addSplitView.glyphSymbol, "rectangle.split.2x1")
        XCTAssertEqual(CommandBarCommand.viewArchive.glyphSymbol, "archivebox")
        XCTAssertEqual(CommandBarCommand.archiveTab.glyphSymbol, "archivebox")
        XCTAssertEqual(CommandBarCommand.observedGlyphs.count, 6)
    }

    /// [07 §5] E27: every command has a real SF Symbol (inferred ones by meaning), and the split
    /// commands share the two-pane rectangle family.
    func testEveryCommandGlyphIsARealSymbol() {
        for command in CommandBarCommand.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: command.glyphSymbol, accessibilityDescription: nil),
                            "\(command) → \(command.glyphSymbol)")
            XCTAssertNotEqual(command.glyphSymbol, "command", "\(command) keeps the generic glyph")
        }
        for split in [CommandBarCommand.addLeftSplit, .addRightSplit, .addTopSplit, .addBottomSplit, .closeSplitPane] {
            XCTAssertTrue(split.glyphSymbol.hasPrefix("rectangle.split"), "\(split)")
        }
    }

    /// [07 §5] E27 observed: only command rows draw the glyph box; search, history and site rows
    /// keep a bare glyph or favicon.
    func testOnlyCommandRowsDrawTheGlyphBox() {
        XCTAssertTrue(commandRow(.openSettings).drawsGlyphBox)
        XCTAssertFalse(searchRow.drawsGlyphBox)
        let history = CommandBarResult(id: "history:1", kind: .historyItem, title: "Swift", iconHint: .history,
                                       actionLabel: "Open", action: .openURL(URL(string: "https://swift.org")!, target: .newTab))
        XCTAssertFalse(history.drawsGlyphBox)
        let site = CommandBarResult(id: "tab:1", kind: .todayTab, title: "Swift", iconHint: .site(faviconURL: nil),
                                    actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()))
        XCTAssertFalse(site.drawsGlyphBox)
    }

    /// The commands source tags its rows so the view can draw the right glyph. [07 §5] E27.
    func testCommandsSourceRowsCarryTheirCommand() async {
        let rows = await CommandBarCommandsSource().results(for: CommandBarQueryContext(text: "settings", mode: .newTab))
        let settings = rows.first { $0.command == .openSettings }
        XCTAssertEqual(settings?.drawsGlyphBox, true)
    }

    // MARK: [07 §5] E27 input glyph

    /// [07 §5] E27 observed: the input glyph is the first result's command glyph (settings →
    /// gear, copy url → copy, split → split, archive → box), else the magnifier.
    func testInputGlyphFollowsTheFirstResult() {
        let cases: [(String, CommandBarCommand, String)] = [
            ("settings", .openSettings, "gearshape"),
            ("copy url", .copyURL, "doc.on.doc"),
            ("split", .addSplitView, "rectangle.split.2x1"),
            ("archive", .viewArchive, "archivebox"),
        ]
        for (text, command, symbol) in cases {
            let glyph = CommandBarInputGlyph.forField(text: text, firstResult: commandRow(command))
            XCTAssertEqual(glyph, .command(command), text)
            XCTAssertEqual(glyph.symbolName, symbol, text)
        }
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "settings", firstResult: searchRow), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "settings", firstResult: nil).symbolName, "magnifyingglass")
        // The empty field keeps the magnifier (B109), even under a help command (incognito).
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "", firstResult: commandRow(.contactTheTeam)), .magnifier)
    }

    // MARK: [07 §5] E27 shortcut chip vs arrow box

    /// [07 §5] E27 observed: a command with a shortcut shows it in a chip and no arrow box; rows
    /// without a shortcut (or with right-hand text) keep the arrow box. [06 §16.2] the hints.
    func testShortcutChipAndArrowBoxAreExclusive() {
        XCTAssertEqual(commandRow(.copyURL).trailingAccessory(for: .window), .shortcutChip("⇧⌘C"))
        XCTAssertEqual(commandRow(.addSplitView).trailingAccessory(for: .window), .shortcutChip("⌃⇧="))
        XCTAssertEqual(commandRow(.archiveTab).trailingAccessory(for: .pane), .shortcutChip("⌘W"))
        XCTAssertEqual(commandRow(.viewArchive).trailingAccessory(for: .pane), .arrowBox)
        var labelled = commandRow(.copyURL)
        labelled.actionLabel = "Switch to Tab"
        XCTAssertEqual(labelled.trailingAccessory(for: .pane), .arrowBox)
    }

    /// [07 §5] E27 follow-up observed (2026-10-30, Arc, typed "weather"): in the window's bar the
    /// site, search, history and command rows show no action text and no arrow box, highlighted
    /// or not; open-tab rows keep theirs.
    func testWindowBarShowsTrailingOnlyForOpenTabsSpec07Section5() {
        XCTAssertEqual(commandRow(.viewArchive).trailingAccessory(for: .window), CommandBarRowAccessory.none)
        XCTAssertEqual(searchRow.trailingAccessory(for: .window), CommandBarRowAccessory.none)
        XCTAssertNil(searchRow.trailingLabel(for: .window, isSelected: true))
        XCTAssertNil(searchRow.trailingLabel(for: .window, isSelected: false))
        XCTAssertEqual(commandRow(.copyURL).trailingAccessory(for: .window), .shortcutChip("⇧⌘C"))
    }

    /// [07 §5] E27 observed: unselected glyph box / chip ≈ #F0F0F0, ≈ 20 pt box; dark inferred.
    func testGlyphBoxTokens() {
        XCTAssertEqual(ThemeDerivation.palette(for: nil).commandBarGlyphBoxFill, RGBAColor(hex: 0xF0F0F0))
        let dark = ThemeDerivation.palette(for: nil, appearance: .dark)
        XCTAssertEqual(dark.commandBarGlyphBoxFill, RGBAColor(hex: 0xFFFFFF, alpha: 0.08))
        XCTAssertEqual(Metrics.CommandBar.commandGlyphBoxSize, 20)
        XCTAssertLessThan(Metrics.CommandBar.commandGlyphBoxSize, Metrics.CommandBar.resultRowHeight)
    }

    // MARK: [07 §5] E27 default-theme selection

    /// [07 §5] E27 observed: #ADABE2 on a Space with no picked color (light); the rule gave
    /// #A5A5BC. Picked colors keep the [07 §8] rule.
    func testDefaultThemeSelectionFill() {
        XCTAssertEqual(ThemeDerivation.palette(for: nil).commandBarSelection, RGBAColor(hex: 0xADABE2))
        let noDots = Theme(id: UUID(), appearance: .light, colors: [], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ThemeDerivation.palette(for: noDots).commandBarSelection, RGBAColor(hex: 0xADABE2))
        let picked = RGBAColor(hex: 0xA5729C)
        let themed = Theme(id: UUID(), appearance: .light, colors: [picked], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ThemeDerivation.palette(for: themed).commandBarSelection,
                       ThemeDerivation.tone(of: picked, lightness: ThemeDerivation.commandBarSelectionLightness,
                                            chromaFactor: ThemeDerivation.commandBarSelectionChromaFactor))
        XCTAssertNotEqual(ThemeDerivation.palette(for: nil, appearance: .dark).commandBarSelection,
                          RGBAColor(hex: 0xADABE2), "dark keeps the rule")
    }

    // MARK: [06 §13] E27 drag handle

    /// [06 §13] E27 observed: no drag handle on the empty panel or `about:blank`; a loaded page
    /// shows it on hover (B84, inferred).
    func testDragHandleHiddenOnBlankPages() {
        let blank = URL(string: "about:blank")!
        let page = URL(string: "https://swift.org/")!
        XCTAssertTrue(MainWindowLayout.isBlankPage(hasSelectedTab: false, url: nil))
        XCTAssertTrue(MainWindowLayout.isBlankPage(hasSelectedTab: false, url: page))
        XCTAssertTrue(MainWindowLayout.isBlankPage(hasSelectedTab: true, url: nil))
        XCTAssertTrue(MainWindowLayout.isBlankPage(hasSelectedTab: true, url: blank))
        XCTAssertFalse(MainWindowLayout.isBlankPage(hasSelectedTab: true, url: page))
        for hovered in [false, true] {
            XCTAssertFalse(MainWindowLayout.showsDragHandle(isBlankPage: true, isHovered: hovered))
        }
        XCTAssertTrue(MainWindowLayout.showsDragHandle(isBlankPage: false, isHovered: true))
        XCTAssertFalse(MainWindowLayout.showsDragHandle(isBlankPage: false, isHovered: false))
    }
}
