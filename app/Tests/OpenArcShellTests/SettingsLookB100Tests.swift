import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B100: the Settings window's look, matched against captures of Arc's light Settings window.
/// Spec: docs/arc-spec/03-settings.md (contents per pane) and 07-design-system.md §3, §6 (body
/// font, window size, toolbar, row pitch). Values marked "B100 capture" are measured on those
/// captures (observed) and wait to be added to the spec.
@MainActor
final class SettingsLookB100Tests: XCTestCase {
    private var shells: [ShellModel] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        shells.forEach { $0.stop() }
        shells = []
    }

    private func makeSettings() -> SettingsModel {
        let shell = ShellModel(dependencies: .fake(), workspace: .demo())
        shells.append(shell)
        return SettingsModel(shell: shell)
    }

    // MARK: 07 §6 window, B100 column and cards

    /// [07 §6] observed 684 pt window; B100 capture: cards span x 64…620 (556 wide), 20 pt under
    /// the toolbar, 9 pt apart, corner 6, 1 pt #ECECEC border on #FDFDFD.
    func testColumnAndCardTokens() {
        XCTAssertEqual(SettingsTokens.windowWidth, 684)
        XCTAssertEqual(SettingsLayout.columnInset, 64)
        XCTAssertEqual(SettingsLayout.columnWidth, 556)
        XCTAssertEqual(SettingsLayout.paneTopPadding, 20)
        XCTAssertEqual(SettingsLayout.cardSpacing, 9)
        XCTAssertEqual(SettingsLayout.cardCornerRadius, 6)
        XCTAssertEqual(SettingsLayout.listCardCornerRadius, 9)
        XCTAssertEqual(SettingsPalette.window, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(SettingsPalette.cardFill, RGBAColor(hex: 0xFDFDFD))
        XCTAssertEqual(SettingsPalette.cardBorder, RGBAColor(hex: 0xECECEC))
        XCTAssertEqual(SettingsPalette.listCardBorder, RGBAColor(hex: 0xDFDFDF))
        XCTAssertEqual(SettingsPalette.toolbarHairline, RGBAColor(hex: 0xE8E8E8))
    }

    /// [07 §6] observed 37 pt toggle pitch: a switch row is 36 tall plus a 1 pt divider; control
    /// rows 43, tiled rows 39 (B100 capture, observed).
    func testRowHeights() {
        XCTAssertEqual(SettingsLayout.toggleRowPitch, 37)
        XCTAssertEqual(SettingsLayout.toggleRowHeight + SettingsLayout.dividerHeight, 37)
        XCTAssertEqual(SettingsLayout.controlRowHeight, 43)
        XCTAssertEqual(SettingsLayout.tileRowHeight, 39)
        XCTAssertEqual(SettingsLayout.dataRowHeight, 34)
    }

    /// [07 §3] observed: Settings body is SF Regular 13; B100 capture: row text #4E4E4E,
    /// secondary #9C9C9C, toolbar labels 11 pt.
    func testTypography() {
        XCTAssertEqual(Typography.settingsBody.size, 13)
        XCTAssertEqual(Typography.settingsToolbarLabel.size, 11)
        XCTAssertEqual(SettingsPalette.bodyText, RGBAColor(hex: 0x4E4E4E))
        XCTAssertEqual(SettingsPalette.secondaryText, RGBAColor(hex: 0x9C9C9C))
    }

    /// The column is centered: a card in the column starts 64 pt from the window's left edge, ends
    /// 64 pt from its right edge and sits 20 pt under the toolbar (B100 capture, observed).
    func testCardsAreCenteredInTheColumn() throws {
        var frames: [CGRect] = []
        let view = SettingsColumn {
            SettingsCard { SettingsToggleRow(label: "Probe", isOn: .constant(true)) }
                .background(GeometryReader { Color.clear.preference(key: CardFramesKey.self, value: [$0.frame(in: .global)]) })
        }
        .frame(width: SettingsTokens.windowWidth)
        .onPreferenceChange(CardFramesKey.self) { frames = $0 }
        host(view, height: 200)
        let card = try XCTUnwrap(frames.first)
        XCTAssertEqual(card.minX, 64, accuracy: 0.5)
        XCTAssertEqual(SettingsTokens.windowWidth - card.maxX, 64, accuracy: 0.5)
        XCTAssertEqual(card.minY, 20, accuracy: 0.5)
        XCTAssertEqual(card.height, 36, accuracy: 0.5, "one switch row: 37 pitch minus the divider [07 §6]")
    }

    // MARK: Switch, buttons, popups

    /// B100 capture, observed: the switch is the small 36 × 16 gray one, with light gray tracks
    /// (off #EBEBEB, on #E0E0E0), not the accent color.
    func testSwitchIsSmallAndGray() {
        XCTAssertEqual(SettingsLayout.switchSize, CGSize(width: 36, height: 16))
        XCTAssertEqual(SettingsPalette.switchOffTrack, RGBAColor(hex: 0xEBEBEB))
        XCTAssertEqual(SettingsPalette.switchOnTrack, RGBAColor(hex: 0xE0E0E0))
        let host = host(SettingsSwitchShape(isOn: true), height: 40)
        XCTAssertEqual(host.fittingSize.width, 36, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, 16, accuracy: 0.5)
    }

    /// The restyled switch still works: a click on it flips the binding, and a disabled one
    /// ignores the click.
    func testSwitchClickFlipsItsBinding() throws {
        final class Box { var value = false }
        for enabled in [true, false] {
            let box = Box()
            let view = Toggle("Probe", isOn: Binding(get: { box.value }, set: { box.value = $0 }))
                .toggleStyle(SettingsSwitchStyle(showsLabel: false))
                .disabled(!enabled)
                .frame(width: 36, height: 16)
            let host = host(view, height: 16, width: 36)
            let window = try XCTUnwrap(host.window)
            let point = host.convert(NSPoint(x: 18, y: 8), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            settle(host)
            XCTAssertEqual(box.value, enabled, enabled ? "a click turns it on" : "disabled: no change")
        }
    }

    /// B100 capture, observed: borderless light-gray buttons and popups, 24 tall, corner 5,
    /// black 5 % fill (#F0F0F0 on a card).
    func testButtonAndPopupTokens() {
        XCTAssertEqual(SettingsLayout.buttonHeight, 24)
        XCTAssertEqual(SettingsLayout.buttonCornerRadius, 5)
        XCTAssertEqual(SettingsPalette.buttonFill.alpha, 0.05, accuracy: 0.001)
        // On the card fill #FDFDFD, 5 % black gives ≈ #F0F0F0.
        let onCard = SettingsPalette.cardFill.red * (1 - SettingsPalette.buttonFill.alpha)
        XCTAssertEqual(onCard * 255, 0xF0, accuracy: 1)
        XCTAssertEqual(SettingsLayout.popupMinWidth, 136)
    }

    /// B100 capture, observed: "12 hours (default)", "6 hours (default)".
    func testPopupMarksTheDefaultChoice() {
        XCTAssertEqual(SettingsDefaults.title("12 hours", isDefault: true), "12 hours (default)")
        XCTAssertEqual(SettingsDefaults.title("24 hours", isDefault: false), "24 hours")
    }

    // MARK: Toolbar

    /// B100 capture, observed: gray outline glyphs, no accent tint; the selected pane gets a light
    /// gray rounded highlight. Glyphs are our own SF Symbol choices.
    func testToolbarGlyphsAndSelection() {
        XCTAssertEqual(SettingsPane.allCases.map(\.systemImage),
                       ["person.text.rectangle", "gearshape", "person", "macwindow.on.rectangle",
                        "keyboard", "scribble.variable", "slider.horizontal.3"])
        for pane in SettingsPane.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: nil), pane.rawValue)
        }
        XCTAssertEqual(SettingsPalette.toolbarSelection, RGBAColor(hex: 0xF9F9F9))
        XCTAssertEqual(SettingsToolbarLayout.highlightCornerRadius, 10)
        // Item width: label plus 7 each side, at least 55 ("Links" 26.5 → 55; "Shortcuts" 50 → 64).
        XCTAssertEqual(SettingsToolbarLayout.itemWidth(labelWidth: 26), 55)
        XCTAssertEqual(SettingsToolbarLayout.itemWidth(labelWidth: 50), 64)
    }

    /// A click on a toolbar item selects its pane, and the window title follows ([03] observed).
    func testToolbarSelectsPaneAndTitleFollows() throws {
        let settings = makeSettings()
        settings.selectedPane = .general
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsWindowView(model: settings))
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        XCTAssertEqual(window.title, "General")
        settings.selectedPane = .advanced
        settle(host)
        XCTAssertEqual(window.title, "Advanced")
    }

    // MARK: Panes

    /// [03 §General]: the first row is the automatic-update switch (Arc's "Info" was its ⓘ), with
    /// our wording, backed by the D7 updater's automatic checks.
    func testGeneralUpdateRowIsLabelledAndLive() {
        let control = SettingsCatalog.control("general.automaticUpdates")
        XCTAssertEqual(control.label, "Automatically update Open Arc")
        XCTAssertEqual(control.kind, .toggle(defaultValue: true))
        XCTAssertTrue(control.isEnabled)
        XCTAssertFalse(SettingsCatalog.controls(in: .general).contains { $0.label == "Info" })
        let settings = makeSettings()
        XCTAssertEqual(settings.updates.automaticallyChecksForUpdates, true)
    }

    /// [03 §Advanced] observed switches, grouped in three cards as Arc does (B100 capture), each
    /// row with a colored tile: blue, green / green / red, purple ×3.
    func testAdvancedCardsAndTiles() {
        XCTAssertEqual(AdvancedPane.cards.flatMap { $0 }, AdvancedPane.toggleIDs)
        XCTAssertEqual(AdvancedPane.cards.map(\.count), [2, 3, 3])
        let colors = AdvancedPane.toggleIDs.map { AdvancedPane.tile($0).color }
        XCTAssertEqual(colors, [SettingsTile.blue, SettingsTile.blue, SettingsTile.green, SettingsTile.green,
                                SettingsTile.red, SettingsTile.purple, SettingsTile.purple, SettingsTile.purple])
        for id in AdvancedPane.toggleIDs {
            XCTAssertNotNil(NSImage(systemSymbolName: AdvancedPane.tile(id).symbol, accessibilityDescription: nil), id)
        }
    }

    /// [03 §Profiles] observed data rows; B100 capture: each has a colored tile (blue lock, green
    /// key, yellow card, orange bell, red trash) and a → arrow.
    func testProfileDataRowTiles() {
        XCTAssertEqual(ProfilesPane.dataRows.map { ProfilesPane.tile($0).color },
                       [SettingsTile.dataBlue, SettingsTile.dataGreen, SettingsTile.dataYellow,
                        SettingsTile.dataOrange, SettingsTile.dataTeal])
        XCTAssertEqual(ProfilesPane.clearDataTile.color, SettingsTile.dataRed)
        for page in ProfilesPane.dataRows {
            XCTAssertNotNil(NSImage(systemSymbolName: ProfilesPane.tile(page).symbol, accessibilityDescription: nil))
        }
    }

    /// The profile list's edit button renames the edited profile through TreeOps; blank names and
    /// unchanged names are ignored.
    func testRenameProfileFromTheList() throws {
        let settings = makeSettings()
        let id = try XCTUnwrap(settings.editedProfileID)
        XCTAssertTrue(settings.renameProfile(id, to: "  Work  "))
        XCTAssertEqual(settings.shell.workspace.profiles[id]?.name, "Work")
        XCTAssertFalse(settings.renameProfile(id, to: "   "))
        XCTAssertFalse(settings.renameProfile(id, to: "Work"))
        XCTAssertEqual(settings.profileRows.first { $0.id == id }?.name, "Work")
    }

    /// [03 §Icon] observed: a list of icons with CURRENT ICON under the current one; B100 capture:
    /// one row per icon, 52 pt tile, 22 pt radio, 80 pt pitch.
    func testIconListTokens() {
        XCTAssertEqual(SettingsTokens.iconTileSize, 52)
        XCTAssertEqual(SettingsTokens.iconRadioSize, 22)
        XCTAssertEqual(SettingsTokens.iconRowHeight, 80)
        XCTAssertEqual(SettingsPalette.radioSelected, RGBAColor(hex: 0x3950F4))
    }

    /// Every pane lays out at the window width with the new chrome, and none is wider.
    func testEveryPaneFitsTheWindowWidth() {
        let settings = makeSettings()
        for pane in SettingsPane.allCases {
            let host = host(SettingsPaneView(pane: pane, model: settings).modifier(SettingsWindowChrome()),
                            height: SettingsTokens.paneMinHeight)
            XCTAssertLessThanOrEqual(host.fittingSize.width, SettingsTokens.windowWidth + 0.5, pane.rawValue)
        }
    }

    // MARK: Helpers

    @discardableResult
    private func host<V: View>(_ view: V, height: CGFloat, width: CGFloat = SettingsTokens.windowWidth) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        return host
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }
}

/// Collects card frames in global coordinates.
private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
