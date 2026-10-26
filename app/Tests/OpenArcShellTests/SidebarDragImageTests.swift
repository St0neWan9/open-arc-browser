import XCTest
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// The sidebar drag image (B44). Spec: [06 §15.1] lifted row (size, fill, opacity, shadow, grab
/// offset), [06 §15.4] compact pill over the Space-name row / address field / window top and the
/// split preview block, [06 §15.5] favorite tile over Favorites; [04 §拖动图像(E17)];
/// design-tokens.json `Metrics.SidebarDrag`.
@MainActor
final class SidebarDragImageTests: XCTestCase {

    private let layout = SidebarLayout()

    /// [06 §15.1] observed: ≈ 258 × 36 (the row); [06 §15.4] observed: pill ≈ 186 × 26;
    /// [06 §15.5] observed: favorite tile ≈ 126 × 47.
    func testShapeSizes() {
        XCTAssertEqual(SidebarDragImageShape.row.size, CGSize(width: 258, height: 36))
        XCTAssertEqual(SidebarDragImageShape.pill.size, CGSize(width: 186, height: 26))
        XCTAssertEqual(SidebarDragImageShape.favoriteTile.size, CGSize(width: 126, height: 47))
        XCTAssertEqual(Metrics.SidebarDrag.rowImageOpacity, 0.85)
        XCTAssertEqual(Metrics.SidebarDrag.rowImageCornerRadius, 10)
        XCTAssertEqual(Metrics.SidebarDrag.pillCornerRadius, 7, "B44 PX: a rounded rectangle, not a capsule")
    }

    /// [06 §15.4, §15.5] observed: the shape follows the zone under the pointer and restores at
    /// once over the list; pinned rows keep the full size.
    func testShapeZones() {
        func shape(_ x: CGFloat, _ y: CGFloat) -> SidebarDragImageShape {
            SidebarDragImageGeometry.shape(at: CGPoint(x: x, y: y), layout: layout)
        }
        // Window top and toolbar row, address field (y 46–82): pill.
        XCTAssertEqual(shape(140, 5), .pill)
        XCTAssertEqual(shape(140, 23), .pill)
        XCTAssertEqual(shape(140, 64), .pill)
        // Favorites (Arc switched at y ≈ 85–135; our band is the collection, 82–145): tile.
        XCTAssertEqual(shape(140, 85), .favoriteTile)
        XCTAssertEqual(shape(140, 113), .favoriteTile)
        XCTAssertEqual(shape(140, 135), .favoriteTile)
        // Space-name row (y 145–181, full width 0–276): pill.
        XCTAssertEqual(shape(1, 150), .pill)
        XCTAssertEqual(shape(275, 180), .pill)
        // The list (pinned rows and Today): back to the full-size row.
        XCTAssertEqual(shape(140, 181), .row)
        XCTAssertEqual(shape(140, 205), .row)
        XCTAssertEqual(shape(140, 600), .row)
        // Outside the sidebar (web panel, outside the window): the full-size row.
        XCTAssertEqual(shape(300, 64), .row)
        XCTAssertEqual(shape(-10, 113), .row)
        // Moving down from the address field to the list and back: pill → tile → pill → row → pill.
        let path: [CGFloat] = [60, 100, 160, 300, 160]
        XCTAssertEqual(path.map { shape(140, $0) }, [.pill, .favoriteTile, .pill, .row, .pill])
    }

    /// [06 §17.1] B43: with the web toolbar on, everything from the favorites down sits 46 pt
    /// higher; the zones move with it.
    func testShapeZonesFollowTheToolbarShift() {
        let shifted = SidebarLayout(isWebToolbarShown: true)
        let shift = shifted.contentShift
        XCTAssertGreaterThan(shift, 0)
        XCTAssertEqual(SidebarDragImageGeometry.shape(at: CGPoint(x: 140, y: 113 - shift), layout: shifted), .favoriteTile)
        XCTAssertEqual(SidebarDragImageGeometry.shape(at: CGPoint(x: 140, y: 160 - shift), layout: shifted), .pill)
        XCTAssertEqual(SidebarDragImageGeometry.shape(at: CGPoint(x: 140, y: 190 - shift), layout: shifted), .row)
    }

    /// [06 §15.1] observed: pressed at (90, 18) inside the row → image left edge = pointer x − 91.5,
    /// top = pointer y − 18 (the image is ≈ 1 pt wider than the row fill on each side). The grab
    /// point keeps its fraction when the image changes shape (inferred).
    func testGrabOffsetIsKept() {
        let fill = CGRect(x: 8, y: 186, width: 260, height: 36)
        let start = SidebarDragImageGeometry.initialFrame(sourceFill: fill)
        XCTAssertEqual(start.size, CGSize(width: 258, height: 36))
        XCTAssertEqual(start.minX, fill.minX - 1.5)
        let press = CGPoint(x: fill.minX + 90, y: fill.minY + 18)
        let grab = SidebarDragImageGeometry.grabFraction(press: press, imageFrame: start)
        let pointer = CGPoint(x: 700, y: 400)
        let frame = SidebarDragImageGeometry.frame(pointer: pointer, grab: grab, shape: .row)
        XCTAssertEqual(pointer.x - frame.minX, 91.5, accuracy: 0.01)
        XCTAssertEqual(pointer.y - frame.minY, 18, accuracy: 0.01)
        // Pill: same fractions of the smaller size.
        let pill = SidebarDragImageGeometry.frame(pointer: pointer, grab: grab, shape: .pill)
        XCTAssertEqual((pointer.x - pill.minX) / pill.width, grab.x, accuracy: 1e-9)
        XCTAssertEqual((pointer.y - pill.minY) / pill.height, 0.5, accuracy: 1e-9)
        XCTAssertTrue(pill.contains(pointer))
        // A press outside the image clamps into it.
        let clamped = SidebarDragImageGeometry.grabFraction(press: CGPoint(x: -50, y: 900), imageFrame: start)
        XCTAssertEqual(clamped, CGPoint(x: 0, y: 1))
    }

    /// [06 §15.1] observed: the lifted row has the theme's selected-row fill and text; the shadow is
    /// visible on light themes and faint on dark. [06 §15.5] observed: the tile is near white
    /// whatever the theme.
    func testStyleFollowsTheTheme() {
        let light = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xC9C6F0)]), appearance: .light)
        let dark = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0x3B3F7A)]), appearance: .dark)
        let lightStyle = SidebarDragImageStyle(palette: light)
        let darkStyle = SidebarDragImageStyle(palette: dark)
        XCTAssertEqual(lightStyle.rowFill, light.selectedTabFill)
        XCTAssertEqual(lightStyle.text, light.selectedTabText)
        XCTAssertEqual(darkStyle.rowFill, dark.selectedTabFill)
        XCTAssertGreaterThan(lightStyle.shadowOpacity, darkStyle.shadowOpacity * 3)
        XCTAssertEqual(lightStyle.tileFill.red, 1)
        XCTAssertEqual(darkStyle.tileFill.red, 1)
    }

    /// [06 §15.5] observed tile samples over three sidebars (lavender #DFE0FA → #F0F0F6, pink light
    /// #F2B0C9 → #F6E5EB, navy dark #7D7E98 → #B9BBC8): white at the token opacity over the
    /// favorites block (window × 0.96) lands within 5/255 (inferred rule).
    func testTileFillMatchesTheSamples() {
        let d = Metrics.SidebarDrag.self
        let samples: [(sidebar: UInt32, tile: UInt32, dark: Bool)] = [
            (0xDFE0FA, 0xF0F0F6, false), (0xF2B0C9, 0xF6E5EB, false), (0x7D7E98, 0xB9BBC8, true),
        ]
        for sample in samples {
            let block = ThemeDerivation.shade(RGBAColor(hex: sample.sidebar), by: ThemeDerivation.controlFillScale)
            let alpha = sample.dark ? d.favoriteTileWhiteOpacityDark : d.favoriteTileWhiteOpacity
            let blended = ThemeDerivation.overlayWhite(block, amount: alpha)
            let expected = RGBAColor(hex: sample.tile)
            XCTAssertEqual(blended.red * 255, expected.red * 255, accuracy: 5)
            XCTAssertEqual(blended.green * 255, expected.green * 255, accuracy: 5)
            XCTAssertEqual(blended.blue * 255, expected.blue * 255, accuracy: 5)
        }
    }

    /// [06 §15.4] observed (E17): the split preview block follows the theme — lavender (light)
    /// #838BFE, navy (dark) #B7B7C9 — and is about half the row wide (≈ 129 × 37). Light reuses
    /// the band rule (≤ 10/255 from the band, which is itself 4/255 from the block): inferred.
    func testSplitPreviewFollowsTheTheme() {
        let lavender = ThemeDerivation.splitPreviewFill(window: RGBAColor(hex: 0xDFE0FA), isDark: false)
        let navy = ThemeDerivation.splitPreviewFill(window: RGBAColor(hex: 0x7D7E98), isDark: true)
        for (got, want) in [(lavender, RGBAColor(hex: 0x838BFE)), (navy, RGBAColor(hex: 0xB7B7C9))] {
            XCTAssertEqual(got.red * 255, want.red * 255, accuracy: 14)
            XCTAssertEqual(got.green * 255, want.green * 255, accuracy: 14)
            XCTAssertEqual(got.blue * 255, want.blue * 255, accuracy: 14)
        }
        XCTAssertEqual(Metrics.SidebarDrag.splitPreviewWidthFraction, 0.5)
        let palette = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xC9C6F0)]), appearance: .light)
        XCTAssertEqual(palette.splitPreviewFill, ThemeDerivation.splitPreviewFill(window: palette.windowBackground, isDark: false))
    }

    /// The image shows the dragged item: favicon + title + ✕ for a Today tab, — for a pinned tab,
    /// the folder glyph for a folder. [06 §15.1] observed (icon + title + ✕).
    func testContentOfTheDraggedItem() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let today = vm.dragImageContent(for: .tab(f.today1))
        XCTAssertEqual(today.title, "today1")
        XCTAssertEqual(today.accessory, .close)
        XCTAssertEqual(vm.dragImageContent(for: .tab(f.pinnedTab)).accessory, .unload)
        XCTAssertEqual(vm.dragImageContent(for: .tab(f.fav1)).accessory, SidebarDragImageContent.Accessory.none)
        let folder = vm.dragImageContent(for: .folder(f.folderA))
        XCTAssertEqual(folder.icon, .folder)
        XCTAssertEqual(folder.title, "A")
        vm.stop()
    }

    /// [06 §15.1] E17 observed: the image lives in a window above the browser window (so it shows
    /// over the web panel and outside the window), follows the pointer, ignores the mouse, and goes
    /// away when the drag ends.
    func testOverlayPanelFollowsThePointer() {
        let controller = SidebarDragImageController()
        let palette = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xC9C6F0)]), appearance: .light)
        let fill = CGRect(x: 8, y: 186, width: 260, height: 36)
        controller.begin(content: SidebarDragImageContent(title: "t", icon: .favicon(nil), accessory: .close),
                         palette: palette, press: CGPoint(x: 98, y: 204), sourceFill: fill, isRowSource: true)
        controller.move(sidebarPoint: CGPoint(x: 140, y: 400), screenPoint: NSPoint(x: 600, y: 500), layout: layout)
        guard let panel = controller.panelForTesting else { return XCTFail("no panel") }
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertEqual(controller.shape, .row)
        let margin = CGFloat(Metrics.SidebarDrag.shadowMargin)
        XCTAssertEqual(panel.frame.width, 258 + 2 * margin, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 36 + 2 * margin, accuracy: 0.5)
        // The pointer sits 18 pt below the image top (y up on screen: top = pointer y + 18).
        XCTAssertEqual(panel.frame.maxY - margin, 518, accuracy: 0.5)
        // Over the Space-name row the panel shrinks to the pill; back over the list it restores.
        controller.move(sidebarPoint: CGPoint(x: 140, y: 160), screenPoint: NSPoint(x: 600, y: 740), layout: layout)
        XCTAssertEqual(controller.shape, .pill)
        XCTAssertEqual(panel.frame.height, 26 + 2 * margin, accuracy: 0.5)
        controller.move(sidebarPoint: CGPoint(x: 140, y: 113), screenPoint: NSPoint(x: 600, y: 787), layout: layout)
        XCTAssertEqual(controller.shape, .favoriteTile)
        XCTAssertEqual(panel.frame.width, 126 + 2 * margin, accuracy: 0.5)
        controller.move(sidebarPoint: CGPoint(x: 140, y: 300), screenPoint: NSPoint(x: 600, y: 600), layout: layout)
        XCTAssertEqual(controller.shape, .row)
        controller.end()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isShowing)
    }
}
