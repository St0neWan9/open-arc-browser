import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Sidebar surface fidelity (plan B89, `docs/f1-review-3.md` P1): selected-row shadow and pressed
/// shade ([07 §4, §7]), the thin hover scroller ([04 §sidebar]) and the favorites hover card
/// ([07 §12]).
@MainActor
final class SidebarSurfaceTests: XCTestCase {

    // MARK: 07 §4 / §7 selected row

    /// [07 §4, §7] observed: the selected fill carries an ≈ 1 pt soft shadow.
    func testSelectedRowShadow_07_4_7() {
        let s = Metrics.Sidebar.selectedRowShadow
        XCTAssertGreaterThan(s.opacity, 0)
        XCTAssertLessThanOrEqual(s.opacity, 0.2, "soft")
        // About 1 pt of visible spread: the blur plus the offset stay within ≈ 2 pt.
        XCTAssertLessThanOrEqual(s.radius + abs(s.offsetY), 2)
        XCTAssertGreaterThan(s.radius, 0)
    }

    /// [07 §7] observed (PX): a held selected row is ≈ 1 % darker (#F0EDF0 → #EEECED), no scale.
    func testPressedSelectedRowIsOnePercentDarker_07_7() {
        XCTAssertEqual(Metrics.Sidebar.pressedRowShade, 0.99)
        let base = RGBAColor(hex: 0xF0EDF0)
        let pressed = SidebarRowFrame<EmptyView>.selectedFill(base, isPressed: true)
        let expected = RGBAColor(hex: 0xEEECED)
        XCTAssertEqual(pressed.red * 255, expected.red * 255, accuracy: 1.5)
        XCTAssertEqual(pressed.green * 255, expected.green * 255, accuracy: 1.5)
        XCTAssertEqual(pressed.blue * 255, expected.blue * 255, accuracy: 1.5)
        XCTAssertEqual(SidebarRowFrame<EmptyView>.selectedFill(base, isPressed: false), base)
    }

    /// [07 §7] observed "已选中行按住时": only a press on the already selected row shows the
    /// pressed shade; it ends on mouse-up.
    func testPressStateOnlyForSelectedRow_07_7() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.pressBegan(.tab(f.today2))
        XCTAssertNil(vm.pressedItemID, "a press on another row only selects it")
        vm.pressEnded()
        vm.pressBegan(.tab(f.today1))
        XCTAssertEqual(vm.pressedItemID, f.today1)
        vm.pressEnded()
        XCTAssertNil(vm.pressedItemID)
        vm.pressBegan(.tab(f.today1))
        vm.beginDrag(.tab(f.today1))
        XCTAssertNil(vm.pressedItemID, "a drag ends the press")
        vm.endDrag()
        vm.stop()
    }

    // MARK: 04 §sidebar scroller

    /// [04 §sidebar] observed: a thin scroller. No knob while the content fits; a thin knob at
    /// the right edge that moves from the top to the bottom of the track.
    func testScrollerKnobGeometry_04_sidebar() throws {
        let viewport = CGSize(width: 276, height: 753)
        XCTAssertNil(SidebarScrollerGeometry.knobFrame(contentFrame: CGRect(x: 0, y: 0, width: 276, height: 700), viewport: viewport))

        let m = Metrics.SidebarScroller.self
        let top = try XCTUnwrap(SidebarScrollerGeometry.knobFrame(contentFrame: CGRect(x: 0, y: 0, width: 276, height: 1575), viewport: viewport))
        XCTAssertLessThanOrEqual(top.width, 6, "thin")
        XCTAssertEqual(top.maxX, viewport.width - CGFloat(m.trailingInset))
        XCTAssertEqual(top.minY, CGFloat(m.trackInset))
        // Knob length ∝ viewport / content.
        XCTAssertEqual(top.height, (753 - 2 * CGFloat(m.trackInset)) * 753 / 1575, accuracy: 0.01)

        let bottom = try XCTUnwrap(SidebarScrollerGeometry.knobFrame(contentFrame: CGRect(x: 0, y: -(1575 - 753), width: 276, height: 1575), viewport: viewport))
        XCTAssertEqual(bottom.maxY, viewport.height - CGFloat(m.trackInset), accuracy: 0.01)
        XCTAssertEqual(bottom.height, top.height, accuracy: 0.01)

        // Very long content keeps a usable knob.
        let long = try XCTUnwrap(SidebarScrollerGeometry.knobFrame(contentFrame: CGRect(x: 0, y: 0, width: 276, height: 100_000), viewport: viewport))
        XCTAssertEqual(long.height, CGFloat(m.minKnobLength))
    }

    /// [04 §sidebar] observed "visible on hover": the knob fades with a Motion token (unknown).
    func testScrollerFadeToken_04_sidebar() {
        XCTAssertEqual(Motion.sidebarScrollerFade.evidence, .unknown)
        XCTAssertGreaterThan(Motion.sidebarScrollerFade.curve.nominalDuration, 0)
        XCTAssertNotNil(ShellMotion.sidebarScrollerFade)
    }

    // MARK: 07 §12 favorites hover card

    /// [07 §12] observed: 240 × 64, radius 11, ≈ #F9F9FB, 0.5 pt outer line.
    func testFavoritesTooltipTokens_07_12() {
        let t = Metrics.FavoritesTooltip.self
        XCTAssertEqual(t.size, Size2D(width: 240, height: 64))
        XCTAssertEqual(t.cornerRadius, 11)
        XCTAssertEqual(t.fillRGB, 0xF9F9FB)
        XCTAssertEqual(t.hairlineWidth, 0.5)
        XCTAssertGreaterThan(t.shadow.offsetY, 0, "darker below than above")
    }

    /// [07 §12] observed: the card is right of the hovered block (AX x 264–504 for a block ending at
    /// x 268) and vertically centered on it. Checked in the 1920 × 985 reference layout: the only
    /// favorite (x 8–268, y 90–137) gives x 264–504, y 81.5–145.5.
    func testFavoritesTooltipFrameInReferenceWindow_07_12() throws {
        let layout = SidebarLayout()
        XCTAssertEqual(layout.windowSize, CGSize(width: 1920, height: 985))
        let block = try XCTUnwrap(layout.favoriteSlotFrames(count: 1).first)
        XCTAssertEqual(block, CGRect(x: 8, y: 90, width: 260, height: 47))
        let card = SidebarFavoritesTooltipLayout.cardFrame(block: block)
        XCTAssertEqual(card.minX, 264)
        XCTAssertEqual(card.maxX, 504)
        XCTAssertEqual(card.size, CGSize(width: 240, height: 64))
        XCTAssertEqual(card.midY, block.midY)

        // Two rows of favorites (n = 5): a second-row block centers the card on itself too.
        let second = layout.favoriteSlotFrames(count: 5)[3]
        let lower = SidebarFavoritesTooltipLayout.cardFrame(block: second)
        XCTAssertEqual(lower.midY, second.midY)
        XCTAssertEqual(lower.minX, second.maxX - 4, "right of its own block")
    }

    /// The card shows after its delay, not when the pointer left first; a drag hides it.
    func testFavoritesTooltipDelay_07_12() async throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.favoriteTooltipDelay = 0.05
        vm.favoriteHoverBegan(f.fav1)
        XCTAssertNil(vm.favoriteTooltipTabID)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.favoriteTooltipTabID, f.fav1)
        vm.favoriteHoverEnded(f.fav1)
        XCTAssertNil(vm.favoriteTooltipTabID)

        vm.favoriteHoverBegan(f.fav2)
        vm.favoriteHoverEnded(f.fav2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(vm.favoriteTooltipTabID)

        vm.favoriteHoverBegan(f.fav2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.favoriteTooltipTabID, f.fav2)
        vm.beginDrag(.tab(f.fav2))
        XCTAssertNil(vm.favoriteTooltipTabID)
        vm.endDrag()
        vm.stop()
    }

    /// The card lays out at its token size with and without the unread line.
    func testFavoritesTooltipViewSize_07_12() {
        for detail in [nil, "No unread emails, you can exhale! 🌿"] {
            let host = NSHostingView(rootView: SidebarFavoritesTooltipView(title: "Mail", detail: detail))
            XCTAssertEqual(host.fittingSize.width, 240, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, 64, accuracy: 0.5)
        }
    }

    // MARK: Literals moved to tokens (f1-review-3 hard-coded literals)

    /// Empty favorites card text styles and row accessory values come from tokens. [06 §21.2]
    /// observed text; sizes inferred.
    func testSidebarLiteralTokens() {
        XCTAssertEqual(Typography.favoritesEmptyTitle, TextStyle(size: 13, weight: .bold))
        XCTAssertEqual(Typography.favoritesEmptyDetail.size, 11)
        XCTAssertEqual(Typography.favoritesEmptyDismiss.size, 9)
        XCTAssertEqual(SidebarLocalTokens.rowAccessoryGlyphSize, 11)
        XCTAssertEqual(SidebarLocalTokens.rowAccessoryInkOpacity, 0.7)
        XCTAssertEqual(SidebarSelectionJump.buttonSize, SidebarLocalTokens.jumpButtonSize)
        XCTAssertEqual(SidebarLocalTokens.jumpButtonShadow.opacity, 0.18)
    }
}
