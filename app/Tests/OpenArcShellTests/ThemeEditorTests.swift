import XCTest
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Theme editor bubble. Acceptance: `06 §2` (appearance segments, color pad with − / +, preset
/// pages, texture slider, brightness knob), `01 §Spaces` (Edit Theme…), `05 §context menus`
/// (Edit Theme Color…). Pad mapping, point limit and live apply are inferred.
@MainActor
final class ThemeEditorTests: XCTestCase {
    private var fixture = SidebarFixture()
    private var counter = 2000
    private let later = Date(timeIntervalSince1970: 5_000)

    private func makeModel() -> ShellModel {
        ShellModel(
            dependencies: .fake(),
            workspace: fixture.ws,
            now: { [unowned self] in self.later },
            makeID: { [unowned self] in
                self.counter += 1
                return SidebarFixture.id(self.counter)
            }
        )
    }

    private func close(_ a: CGPoint, _ b: CGPoint, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(a.x), Double(b.x), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(a.y), Double(b.y), accuracy: accuracy, file: file, line: line)
    }

    // MARK: Pad <-> color [06 §2]

    /// [06 §2] inferred mapping: position -> color -> position returns the same spot.
    func testPadPositionColorRoundTrip() {
        for x in stride(from: 0.0, to: 1.0, by: 0.05) {
            for y in stride(from: 0.0, through: 1.0, by: 0.1) {
                let p = CGPoint(x: x, y: y)
                close(ThemePad.position(of: ThemePad.color(at: p)), p)
            }
        }
    }

    /// The pad covers the whole hue wheel; vivid at the top, muted at the bottom (inferred).
    func testPadMappingAxes() {
        let red = ThemePad.color(at: CGPoint(x: 0, y: 0))
        XCTAssertGreaterThan(red.red, red.green)
        XCTAssertEqual(red.red, ThemePad.value, accuracy: 1e-9)
        let top = ThemePad.hsv(of: ThemePad.color(at: CGPoint(x: 0.5, y: 0)))
        let bottom = ThemePad.hsv(of: ThemePad.color(at: CGPoint(x: 0.5, y: 1)))
        XCTAssertEqual(top.saturation, ThemePad.topSaturation, accuracy: 1e-9)
        XCTAssertEqual(bottom.saturation, ThemePad.bottomSaturation, accuracy: 1e-9)
        XCTAssertEqual(top.hue, 0.5, accuracy: 1e-9)
        // Positions outside the pad are clamped.
        XCTAssertEqual(ThemePad.color(at: CGPoint(x: -3, y: 9)), ThemePad.color(at: CGPoint(x: 0, y: 1)))
    }

    /// A preset color has no pad position of its own; it lands somewhere valid on the pad.
    func testPresetColorsMapInsideThePad() {
        for group in ThemePresets.groups {
            for color in group.colors {
                let p = ThemePad.position(of: color)
                XCTAssertTrue((0...1).contains(Double(p.x)) && (0...1).contains(Double(p.y)))
            }
        }
    }

    // MARK: Points [06 §2]

    /// [06 §2] observed: with no point placed, − and + are grayed out.
    func testNoPointsMeansMinusAndPlusAreDisabled() {
        let draft = SpaceThemeDraft(colors: [])
        XCTAssertFalse(draft.canAddPoint)
        XCTAssertFalse(draft.canRemovePoint)
    }

    /// [06 §2] observed: the first tap places a point; "+" adds more up to the limit, "−" removes.
    func testPointLimitsAndAddRemove() {
        var draft = SpaceThemeDraft(colors: [])
        _ = draft.beginPadInteraction(at: CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(draft.colors.count, 1)
        XCTAssertTrue(draft.canAddPoint)
        XCTAssertTrue(draft.canRemovePoint)

        while draft.canAddPoint { draft.addPoint() }
        XCTAssertEqual(draft.colors.count, ThemePad.maxPoints)
        XCTAssertFalse(draft.canAddPoint)
        draft.addPoint()   // no effect at the limit
        XCTAssertEqual(draft.colors.count, ThemePad.maxPoints)
        XCTAssertEqual(Set(draft.colors).count, ThemePad.maxPoints, "added points are distinguishable")

        let first = draft.colors[0]
        draft.removeLastPoint()
        XCTAssertEqual(draft.colors.count, ThemePad.maxPoints - 1)
        XCTAssertEqual(draft.colors[0], first, "removing takes the most recent point")
        while draft.canRemovePoint { draft.removeLastPoint() }
        XCTAssertTrue(draft.colors.isEmpty)
        draft.removeLastPoint()
        XCTAssertTrue(draft.colors.isEmpty)
    }

    /// Pressing on a point grabs it (a drag moves it); pressing on empty space places a new one.
    func testPressGrabsExistingPointOrPlacesANewOne() {
        var draft = SpaceThemeDraft(colors: [ThemePad.color(at: CGPoint(x: 0.2, y: 0.2))])
        let grabbed = draft.beginPadInteraction(at: CGPoint(x: 0.22, y: 0.21))
        XCTAssertEqual(grabbed, 0)
        XCTAssertEqual(draft.colors.count, 1)

        draft.movePoint(grabbed, to: CGPoint(x: 0.6, y: 0.7))
        close(ThemePad.position(of: draft.colors[0]), CGPoint(x: 0.6, y: 0.7))

        let placed = draft.beginPadInteraction(at: CGPoint(x: 0.9, y: 0.9))
        XCTAssertEqual(placed, 1)
        XCTAssertEqual(draft.colors.count, 2)
    }

    /// At the limit a press on empty space moves the nearest point instead of adding one (inferred).
    func testPressAtTheLimitMovesTheNearestPoint() {
        var draft = SpaceThemeDraft(colors: [
            ThemePad.color(at: CGPoint(x: 0.1, y: 0.1)),
            ThemePad.color(at: CGPoint(x: 0.5, y: 0.5)),
            ThemePad.color(at: CGPoint(x: 0.9, y: 0.9)),
        ])
        let index = draft.beginPadInteraction(at: CGPoint(x: 0.75, y: 0.95))
        XCTAssertEqual(index, 2)
        XCTAssertEqual(draft.colors.count, 3)
        close(ThemePad.position(of: draft.colors[2]), CGPoint(x: 0.75, y: 0.95))
    }

    // MARK: Presets [06 §2]

    /// [06 §2] observed: nine round swatches per page, several named groups.
    func testPresetPagesHoldNineSwatchesAndAreNamed() {
        XCTAssertGreaterThanOrEqual(ThemePresets.groups.count, 3)
        XCTAssertTrue(ThemePresets.groups.allSatisfy { $0.colors.count == 9 })
        XCTAssertEqual(ThemePresets.groups.map(\.name).prefix(3), ["Brand", "Pastel", "Drab"])
        XCTAssertEqual(Set(ThemePresets.groups.flatMap(\.colors)).count, ThemePresets.groups.count * 9, "no duplicate swatches")
    }

    /// The arrows page left and right and stop at the ends (inferred).
    func testPagingStopsAtTheEnds() {
        let last = ThemePresets.groups.count - 1
        XCTAssertEqual(ThemePresets.page(after: 0, step: -1), 0)
        XCTAssertEqual(ThemePresets.page(after: 0, step: 1), 1)
        XCTAssertEqual(ThemePresets.page(after: last, step: 1), last)
        XCTAssertEqual(ThemePresets.pageContaining(ThemePresets.groups[1].colors[4]), 1)
        XCTAssertEqual(ThemePresets.pageContaining(nil), 0)
    }

    func testApplyingAPresetReplacesAllPoints() {
        var draft = SpaceThemeDraft(colors: [ThemePad.color(at: .zero), ThemePad.color(at: CGPoint(x: 0.5, y: 0.5))])
        let preset = ThemePresets.groups[0].colors[3]
        draft.applyPreset(preset)
        XCTAssertEqual(draft.colors, [preset])
    }

    // MARK: Slider and knob [06 §2]

    func testSliderValueIsClampedToTheTrack() {
        XCTAssertEqual(ThemeControlMath.sliderValue(x: -20, width: 100, inset: 6), 0)
        XCTAssertEqual(ThemeControlMath.sliderValue(x: 300, width: 100, inset: 6), 1)
        XCTAssertEqual(ThemeControlMath.sliderValue(x: 50, width: 100, inset: 6), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ThemeControlMath.sliderValue(x: 5, width: 8, inset: 6), 0, "a track with no room is 0")
    }

    func testKnobSweepsFromLowerLeftOverTheTopToLowerRight() {
        XCTAssertEqual(ThemeControlMath.knobValue(dx: 0, dy: -10), 0.5, accuracy: 1e-9)   // 12 o'clock
        XCTAssertEqual(ThemeControlMath.knobValue(dx: -10, dy: 10), 0, accuracy: 1e-9)    // 7:30
        XCTAssertEqual(ThemeControlMath.knobValue(dx: 10, dy: 10), 1, accuracy: 1e-9)     // 4:30
        XCTAssertEqual(ThemeControlMath.knobValue(dx: -1, dy: 10), 0, accuracy: 1e-9)     // gap snaps to nearer end
        XCTAssertEqual(ThemeControlMath.knobValue(dx: 1, dy: 10), 1, accuracy: 1e-9)
        XCTAssertEqual(ThemeControlMath.knobAngle(value: 0), -135, accuracy: 1e-9)
        XCTAssertEqual(ThemeControlMath.knobAngle(value: 1), 135, accuracy: 1e-9)
        for v in stride(from: 0.0, through: 1.0, by: 0.1) {
            let a = ThemeControlMath.knobAngle(value: v) * .pi / 180
            XCTAssertEqual(ThemeControlMath.knobValue(dx: sin(a) * 10, dy: -cos(a) * 10), v, accuracy: 1e-9)
        }
    }

    // MARK: Live apply [06 §2, inferred]

    private func editedModel(spaceID: UUID? = nil) -> (ShellModel, UUID) {
        let model = makeModel()
        let id = spaceID ?? fixture.home
        model.selectSpace(id)
        return (model, id)
    }

    /// Spaces ▸ Edit Theme… and Edit Theme Color… (the `.editSpaceTheme` request) open the bubble.
    func testEditThemeRequestOpensTheBubble() {
        let (model, id) = editedModel()
        XCTAssertNil(model.spaceFlow.themeEditorSpaceID)
        model.sidebar.requestFromMenu(.editSpaceTheme(spaceID: id))
        XCTAssertEqual(model.spaceFlow.themeEditorSpaceID, id)
        model.spaceFlow.closeThemeEditor()
        XCTAssertNil(model.spaceFlow.themeEditorSpaceID)
        model.stop()
    }

    /// The bubble does not open for a missing Space, nor over the creation view.
    func testEditThemeIsIgnoredForUnknownSpaceOrWhileCreating() {
        let (model, _) = editedModel()
        model.spaceFlow.beginEditTheme(spaceID: SidebarFixture.id(9999))
        XCTAssertNil(model.spaceFlow.themeEditorSpaceID)
        model.spaceFlow.beginCreate()
        model.spaceFlow.beginEditTheme(spaceID: fixture.home)
        XCTAssertNil(model.spaceFlow.themeEditorSpaceID)
        model.stop()
    }

    /// A Space without a theme starts with no color points and the default palette.
    func testSpaceWithoutThemeStartsEmpty() {
        let (model, id) = editedModel()
        let draft = model.spaceFlow.themeDraft(of: id)
        XCTAssertTrue(draft.colors.isEmpty)
        XCTAssertEqual(draft.appearance, .automatic)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(ThemeDerivation.defaultBaseColor))
        model.stop()
    }

    /// Each pad edit updates the selected Space's palette at once; a Space with no theme gets a
    /// theme record, and only the `theme` group of the Space is stamped.
    func testPadEditUpdatesThePaletteLive() throws {
        let (model, id) = editedModel()
        var draft = model.spaceFlow.themeDraft(of: id)
        _ = draft.beginPadInteraction(at: CGPoint(x: 0.6, y: 0.2))
        model.spaceFlow.applyThemeDraft(draft, to: id)

        let space = try XCTUnwrap(model.workspace.spaces[id])
        let themeID = try XCTUnwrap(space.themeID)
        let theme = try XCTUnwrap(model.workspace.themes[themeID])
        XCTAssertEqual(theme.colors, draft.colors)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(draft.colors[0]))
        XCTAssertEqual(space.meta.modifiedAt(Space.FieldGroup.theme), later)
        XCTAssertNotEqual(space.meta.modifiedAt(Space.FieldGroup.naming), later, "naming is not touched")

        // Dragging the point changes the same theme record; the Space itself is not stamped again.
        let before = model.workspace
        draft.movePoint(0, to: CGPoint(x: 0.1, y: 0.8))
        model.spaceFlow.applyThemeDraft(draft, to: id)
        XCTAssertEqual(model.workspace.spaces[id]?.themeID, themeID)
        XCTAssertEqual(model.workspace.themes.count, before.themes.count)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(draft.colors[0]))
        XCTAssertNotEqual(model.sidebar.palette.windowBackground, before.themes[themeID]?.colors.first.map(ThemeDerivation.lightWindow))
        model.stop()
    }

    /// Appearance and grain go to the stored theme; only `Theme.style` is stamped.
    func testAppearanceAndGrainChangesAreStored() throws {
        let (model, id) = editedModel()
        var draft = model.spaceFlow.themeDraft(of: id)
        draft.colors = [ThemePresets.groups[0].colors[0]]
        model.spaceFlow.applyThemeDraft(draft, to: id)
        let themeID = try XCTUnwrap(model.workspace.spaces[id]?.themeID)

        draft.appearance = .dark
        draft.grain = 0.6
        model.spaceFlow.applyThemeDraft(draft, to: id)
        let theme = try XCTUnwrap(model.workspace.themes[themeID])
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.grain, 0.6, accuracy: 1e-9)
        XCTAssertEqual(theme.colors, draft.colors)
        XCTAssertEqual(theme.meta.modifiedAt(Theme.FieldGroup.style), later)
        XCTAssertEqual(model.spaceFlow.themeDraft(of: id), draft, "reopening the bubble shows the stored values")
        model.stop()
    }

    /// [06 §2] ring knob (brightness, inferred): the knob value is stored as `Theme.brightness` in
    /// the `style` group, reopening shows it, and the window color follows it.
    func testBrightnessKnobIsStoredAndChangesThePalette() throws {
        let (model, id) = editedModel()
        var draft = model.spaceFlow.themeDraft(of: id)
        draft.colors = [RGBAColor(hex: 0x3D6FE0)]
        model.spaceFlow.applyThemeDraft(draft, to: id)
        let themeID = try XCTUnwrap(model.workspace.spaces[id]?.themeID)
        XCTAssertEqual(model.workspace.themes[themeID]?.brightness, Theme.defaultBrightness)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(draft.colors[0]), "neutral knob keeps the color")

        draft.brightness = 0.9
        model.spaceFlow.applyThemeDraft(draft, to: id)
        let theme = try XCTUnwrap(model.workspace.themes[themeID])
        XCTAssertEqual(theme.brightness, 0.9, accuracy: 1e-9)
        XCTAssertEqual(theme.meta.modifiedAt(Theme.FieldGroup.style), later)
        XCTAssertEqual(model.spaceFlow.themeDraft(of: id).brightness, 0.9, accuracy: 1e-9, "reopening shows the knob value")
        XCTAssertGreaterThan(
            ThemeDerivation.luminance(model.sidebar.palette.windowBackground),
            ThemeDerivation.luminance(draft.colors[0]),
            "a brighter knob lightens the window"
        )
        model.stop()
    }

    /// An unchanged draft does not touch the workspace (no stamp, no version bump).
    func testUnchangedDraftIsANoOp() throws {
        let (model, id) = editedModel()
        var draft = model.spaceFlow.themeDraft(of: id)
        draft.colors = [ThemePresets.groups[1].colors[0]]
        model.spaceFlow.applyThemeDraft(draft, to: id)
        let before = model.workspace
        model.spaceFlow.applyThemeDraft(draft, to: id)
        XCTAssertEqual(model.workspace, before)
        model.stop()
    }

    /// Editing one Space's theme leaves the other Spaces alone.
    func testEditingOneSpaceDoesNotChangeAnother() {
        let (model, id) = editedModel()
        var draft = model.spaceFlow.themeDraft(of: id)
        draft.applyPreset(ThemePresets.groups[2].colors[0])
        model.spaceFlow.applyThemeDraft(draft, to: id)
        XCTAssertNil(model.workspace.spaces[fixture.work]?.themeID)
        model.selectSpace(fixture.work)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(ThemeDerivation.defaultBaseColor))
        model.stop()
    }

    /// Closing the bubble keeps what was applied: Arc applies edits live (inferred), so there is no cancel.
    func testClosingKeepsAppliedEdits() throws {
        let (model, id) = editedModel()
        model.spaceFlow.beginEditTheme(spaceID: id)
        var draft = model.spaceFlow.themeDraft(of: id)
        draft.applyPreset(ThemePresets.groups[0].colors[5])
        model.spaceFlow.applyThemeDraft(draft, to: id)
        model.spaceFlow.closeThemeEditor()
        XCTAssertNil(model.spaceFlow.themeEditorSpaceID)
        XCTAssertEqual(model.sidebar.palette.windowBackground, ThemeDerivation.lightWindow(ThemePresets.groups[0].colors[5]))
        model.stop()
    }

    /// A tombstoned theme record is replaced by a new one instead of being edited.
    func testTombstonedThemeGetsReplaced() throws {
        let themeID = SidebarFixture.id(700), newID = SidebarFixture.id(701)
        var ws = fixture.ws
        ws.themes[themeID] = Theme(id: themeID, colors: [RGBAColor(hex: 0x123456)], now: fixture.now)
        ws.themes[themeID]?.meta.markDeleted(at: fixture.now)
        ws.spaces[fixture.home]?.themeID = themeID
        var draft = SpaceThemeDraft(colors: [RGBAColor(hex: 0xABCDEF)])
        draft.grain = 0.2
        let out = try TreeOps.editSpaceTheme(ws, spaceID: fixture.home, newThemeID: newID, style: draft.style, now: later)
        XCTAssertEqual(out.spaces[fixture.home]?.themeID, newID)
        XCTAssertEqual(out.themes[newID]?.colors, draft.colors)
        XCTAssertTrue(out.themes[themeID]?.meta.isTombstone == true)
    }

    func testEditingAMissingSpaceThrows() {
        XCTAssertThrowsError(try TreeOps.editSpaceTheme(
            fixture.ws, spaceID: SidebarFixture.id(9999), newThemeID: SidebarFixture.id(1), style: SpaceThemeDraft().style, now: later
        )) { XCTAssertEqual($0 as? TreeError, .notFound(SidebarFixture.id(9999))) }
    }

    // MARK: Creation flow

    /// [06 §2] observed: from "Choose a Theme" the bubble edits the new Space's draft theme, which
    /// becomes its theme on Create.
    func testDraftThemeBecomesTheNewSpacesTheme() throws {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Study"
        var draft = model.spaceFlow.draftTheme
        draft.appearance = .light
        draft.applyPreset(ThemePresets.groups[1].colors[2])
        draft.grain = 0.4
        model.spaceFlow.draftTheme = draft
        let id = try XCTUnwrap(model.spaceFlow.create())
        let themeID = try XCTUnwrap(model.workspace.spaces[id]?.themeID)
        let theme = try XCTUnwrap(model.workspace.themes[themeID])
        XCTAssertEqual(theme.appearance, .light)
        XCTAssertEqual(theme.colors, [ThemePresets.groups[1].colors[2]])
        XCTAssertEqual(theme.grain, 0.4, accuracy: 1e-9)
        model.stop()
    }

    // MARK: Palette with several colors

    /// Several color points give a gradient-ready palette; the first stays the base.
    func testSeveralPointsGiveGradientStops() {
        let colors = [ThemePad.color(at: CGPoint(x: 0.1, y: 0.2)), ThemePad.color(at: CGPoint(x: 0.6, y: 0.4))]
        let palette = ThemeDerivation.palette(for: Theme(id: UUID(), colors: colors, now: fixture.now))
        XCTAssertEqual(palette.backgroundGradientColors, colors.map(ThemeDerivation.lightWindow), "[07 §8] each stop mapped like the window")
        XCTAssertEqual(palette.windowBackground, ThemeDerivation.lightWindow(colors[0]))
    }
}
