import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Layout numbers at the 1920x985 pt reference window. [07 §1, §2, §4] observed (E11).
final class SidebarLayoutTests: XCTestCase {
    private let layout = SidebarLayout(windowSize: CGSize(width: 1920, height: 985))

    /// URL box placeholder: magnifier cell at (14, 52), 24 × 24, text from x 41 (round-1
    /// comparison, B32, AX + PX observed); a domain keeps the x 20 text start [07 §4] observed.
    func testURLBoxMagnifierAndTextStart() {
        let s = Metrics.Sidebar.self
        XCTAssertEqual(s.addressFieldIconFrame, Rect2D(x: 14, y: 52, width: 24, height: 24))
        XCTAssertEqual(s.addressFieldTextLeadingAfterIcon, 41)
        XCTAssertEqual(s.addressFieldTextLeading, 20)
        // The icon cell sits inside the 36 pt box, vertically centered on it.
        XCTAssertEqual(s.addressFieldIconFrame.y + s.addressFieldIconFrame.height / 2, s.addressFieldTop + s.addressFieldHeight / 2)
    }

    /// Scroll-edge lines (B32 round 1 observed in a scrolled list; shown only while scrolled, inferred).
    func testScrollEdgesFollowTheContentFrame() {
        XCTAssertEqual(SidebarScrollEdges(contentFrame: CGRect(x: 0, y: 0, width: 276, height: 300), viewportHeight: 754), SidebarScrollEdges())
        XCTAssertEqual(SidebarScrollEdges(contentFrame: CGRect(x: 0, y: 0, width: 276, height: 900), viewportHeight: 754), SidebarScrollEdges(bottom: true))
        XCTAssertEqual(SidebarScrollEdges(contentFrame: CGRect(x: 0, y: -400, width: 276, height: 1557), viewportHeight: 754), SidebarScrollEdges(top: true, bottom: true))
        XCTAssertEqual(SidebarScrollEdges(contentFrame: CGRect(x: 0, y: -803, width: 276, height: 1557), viewportHeight: 754), SidebarScrollEdges(top: true))
        XCTAssertEqual(SidebarScrollEdges(contentFrame: CGRect(x: 0, y: -0.3, width: 276, height: 754.2), viewportHeight: 754), SidebarScrollEdges(), "rounding slack")
    }

    /// Round-2 side-by-side (B33, `docs/arc-spec/07-design-system.md` §10, observed ink; point
    /// sizes fitted): Space icons are ≈ 14 pt glyphs (header and dock), the favicon placeholder is
    /// a 14 pt square 2 pt inside the 18 pt cell, and the list keeps ≈ 260 pt of space after its
    /// last row (from the reference's scroller), so the bottom edge line shows near the dock.
    func testRound2SidebarTokens() {
        XCTAssertEqual(SidebarLocalTokens.spaceIconGlyphSize, 14)
        XCTAssertEqual(SidebarLocalTokens.dockSpaceGlyphSize, 14)
        XCTAssertLessThan(SidebarLocalTokens.spaceIconGlyphSize, CGFloat(Metrics.Sidebar.spaceIconFrame.width))
        XCTAssertEqual(SidebarLocalTokens.faviconPlaceholderInset, 2)
        XCTAssertEqual(SidebarLocalTokens.faviconPlaceholderCornerRadius, 3.5)
        XCTAssertEqual(SidebarLocalTokens.textInkInset, 1)
        XCTAssertEqual(SidebarLocalTokens.listTrailingSpace, 260)
        // Rows ending 56 pt above the dock (the reference capture) show the bottom line.
        let viewport: CGFloat = 754, rowsEnd = viewport - 56
        let edges = SidebarScrollEdges(contentFrame: CGRect(x: 0, y: 0, width: 276, height: rowsEnd + SidebarLocalTokens.listTrailingSpace), viewportHeight: viewport)
        XCTAssertEqual(edges, SidebarScrollEdges(bottom: true))
    }

    /// [07 §1] observed: the web panel starts at x = 276, so the sidebar is 276 wide.
    func testSidebarWidthMatchesWebPanelEdge() {
        XCTAssertEqual(layout.width, 276)
        XCTAssertEqual(layout.width, CGFloat(Metrics.Sidebar.width))
        XCTAssertEqual(MainWindowLayout(windowSize: CGSize(width: 1920, height: 985)).webPanelFrame.minX, layout.width)
    }

    /// [07 §4] observed: URL box x 8–268, y 46–82; favorites x 8–268, y 90–137; both agree with
    /// the window layout.
    func testUrlBoxAndFavoritesUseMeasuredFrames() {
        XCTAssertEqual(layout.urlBoxFrame, CGRect(x: 8, y: 46, width: 260, height: 36))
        XCTAssertEqual(layout.favoritesFrame, CGRect(x: 8, y: 90, width: 260, height: 47))
        let window = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        XCTAssertEqual(layout.urlBoxFrame, window.addressFieldFrame)
        XCTAssertEqual(layout.favoritesFrame, window.favoritesFrame)
    }

    /// [07 §2] observed: hide sidebar / back / forward / reload are 32 × 32 at x 77 / 170 / 204 /
    /// 238, y 7.5–39.5 (center 23.5, beside the traffic lights at y 24).
    func testToolbarButtonsAtMeasuredFrames() {
        XCTAssertEqual(layout.hideSidebarButtonFrame, CGRect(x: 77, y: 7.5, width: 32, height: 32))
        XCTAssertEqual(layout.backButtonFrame, CGRect(x: 170, y: 7.5, width: 32, height: 32))
        XCTAssertEqual(layout.forwardButtonFrame, CGRect(x: 204, y: 7.5, width: 32, height: 32))
        XCTAssertEqual(layout.reloadButtonFrame, CGRect(x: 238, y: 7.5, width: 32, height: 32))
        XCTAssertEqual(layout.reloadButtonFrame.midY, 23.5)
    }

    /// [07 §2] observed: traffic light hit boxes at (12, 16), (35, 16), (58, 16); Library + (3, 4).
    func testTrafficLightFrames() {
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, inLibrary: false), CGRect(x: 12, y: 16, width: 16, height: 16))
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 1, inLibrary: false).midX, 43)
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 2, inLibrary: false).midX, 66)
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 2, inLibrary: false).midY, 24)
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, inLibrary: true).origin, CGPoint(x: 15, y: 20))
    }

    /// [07 §4] observed: the Space header line (icon 26 × 26 at (13, 150)) ends with the More strip
    /// at x 261–263; the list starts at 181 with a 3 pt spacer.
    func testSpaceHeaderAndListTop() {
        XCTAssertEqual(layout.spaceNameRowFrame.minX, 13)
        XCTAssertEqual(layout.spaceNameRowFrame.minY, 150)
        XCTAssertEqual(layout.spaceNameRowFrame.height, 26)
        XCTAssertEqual(layout.spaceNameRowFrame.maxX, 263)
        XCTAssertEqual(layout.listTop, 181)
        XCTAssertEqual(layout.firstRowTop, 184)
    }

    /// [07 §1, §4] observed: rows are full-width 41 pt outline rows back to back; the selected
    /// fill is x 8–268, 36 tall, 2 pt inside the 40 pt button.
    func testRowsSitAtTheObservedPitch() {
        let frames = layout.listItemFrames([.row, .row, .row, .row])
        XCTAssertEqual(layout.rowPitch, 41)
        for index in 1..<frames.count {
            XCTAssertEqual(frames[index].minY - frames[index - 1].minY, CGFloat(Metrics.Sidebar.rowPitch))
            XCTAssertEqual(frames[index].width, 276)
        }
        XCTAssertEqual(frames[0].minY, layout.firstRowTop)
        XCTAssertEqual(layout.rowFillFrame, CGRect(x: 8, y: 2, width: 260, height: 36))
    }

    /// [07 §4] observed: icon x 17–35 (18 × 18, 11 pt below the row top), title text frame at x 43.
    func testIconAndTitleEdges() {
        XCTAssertEqual(layout.rowIconLeading, 17)
        XCTAssertEqual(layout.rowIconSize, 18)
        XCTAssertEqual(layout.rowTitleLeading, 43)
        XCTAssertEqual(layout.rowTitleGap, 8)
        XCTAssertEqual((layout.rowButtonHeight - layout.rowIconSize) / 2, 11)
    }

    /// [07 §1] observed: the divider row is 17 pt; New Tab follows it at the row pitch.
    func testDividerRowInList() {
        let frames = layout.listItemFrames([.row, .divider, .newTabRow, .row])
        XCTAssertEqual(frames[1].height, 17)
        XCTAssertEqual(frames[1].minY, frames[0].maxY)
        XCTAssertEqual(frames[2].minY, frames[1].maxY)
        XCTAssertEqual(frames[3].minY - frames[2].minY, layout.rowPitch)
    }

    /// [07 §4] observed: dock buttons centered on H − 25: Home x 8, "+" x 236, Space icons from
    /// x 42 sharing up to x 234 (pitch 27.5 for 7, 24 for 8; frames 2 pt wider, 34 tall).
    func testDockAtWindowBottom() {
        XCTAssertEqual(layout.dockFrame.maxY, 985)
        XCTAssertEqual(layout.dockHomeFrame, CGRect(x: 8, y: 944, width: 32, height: 32))
        XCTAssertEqual(layout.dockPlusFrame, CGRect(x: 236, y: 944, width: 32, height: 32))
        // Arc shares the band evenly (7 Spaces at 27.5, 8 at 24); ours keeps 30 (B249, the user's
        // choice), so 6 fit: 192 / 6 = 32.
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 6), 32)
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 7), 32, "scrolling: six whole icons")
        let six = layout.dockItemFrames(count: 6)
        XCTAssertEqual(six[0].minX, 41)
        XCTAssertEqual(six[0].minY, 943)
        XCTAssertEqual(six[0].height, 34)
        XCTAssertEqual(six[0].width, 34, accuracy: 0.1)
        XCTAssertEqual(six[1].minX, 73, accuracy: 0.1)
    }

    /// B249 / B253: many Spaces keep at least 30 pt per icon and scroll sideways instead of piling
    /// up; when they scroll, the band holds a whole number of icons, and the current Space's icon
    /// is scrolled into it.
    func testCrowdedDockScrollsInsteadOfOverlapping() {
        XCTAssertEqual(SidebarLayout.dockScrollLimit(count: 6), 0, "six fit")
        XCTAssertGreaterThan(SidebarLayout.dockScrollLimit(count: 7), 0, "seven scroll")
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 13), 32, "six whole icons in 192")
        // As wide as the user's Arc sidebar (361): nine at 30.8, like Arc's 31.
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 9, trailingShift: 85), 277.0 / 9, accuracy: 0.01)
        XCTAssertEqual(SidebarLayout.dockScrollLimit(count: 9, trailingShift: 85), 0)
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 13, trailingShift: 85), 277.0 / 9, accuracy: 0.01)
        let limit = SidebarLayout.dockScrollLimit(count: 13)
        XCTAssertEqual(limit, 13 * 32 - 192)
        XCTAssertEqual(SidebarLayout.dockScroll(-50, count: 13), 0)
        XCTAssertEqual(SidebarLayout.dockScroll(1_000, count: 13), limit)
        XCTAssertEqual(SidebarLayout.dockScroll(0, keeping: 12, count: 13), limit, "last one: ends at the band's edge")
        XCTAssertEqual(SidebarLayout.dockScroll(0, keeping: 7, count: 13), 64, "whole icons: 2 scrolled out")
        XCTAssertEqual(SidebarLayout.dockScroll(64, keeping: 4, count: 13), 64, "already in view: no move")
        XCTAssertEqual(SidebarLayout.dockScroll(limit, keeping: 0, count: 13), 0)
        let frames = layout.dockItemFrames(count: 13, scroll: limit)
        XCTAssertFalse(layout.dockItemIsVisible(frames[0]))
        XCTAssertTrue(layout.dockItemIsVisible(frames[12]))
        XCTAssertEqual(frames[12].maxX - 1, 234, accuracy: 0.01)
        XCTAssertEqual(frames[7].minX + 1, 42, accuracy: 0.01, "the first visible icon starts at the band's edge")
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(b.minX - a.minX, 32, accuracy: 0.001)
        }
    }

    /// B253: on a light-ink (dark) window the current Space's dock icon is near-white, not its
    /// theme's dark tone; dark ink keeps the tone. Arc's violet Space: current 90 %, others 18 %.
    @MainActor
    func testDockIconInk() {
        let violet = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(red: 0.116, green: 0.021, blue: 1.04)], intensity: 1), appearance: .light)
        XCTAssertTrue(violet.usesLightInk)
        let current = SidebarDockIconInk.ink(window: violet, space: violet, tinted: true)
        XCTAssertEqual(current.color, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(current.opacity, 0.90)
        XCTAssertEqual(SidebarDockIconInk.ink(window: violet, space: violet, tinted: false).opacity, 0.18)
        let peach = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xFF8558)]), appearance: .light)
        XCTAssertFalse(peach.usesLightInk)
        let peachCurrent = SidebarDockIconInk.ink(window: peach, space: peach, tinted: true)
        XCTAssertEqual(peachCurrent.color, peach.seamIndicator)
        XCTAssertEqual(peachCurrent.opacity, 1)
    }

    func testDockWheelDelta() {
        XCTAssertEqual(DockScrollWheelCatcher.delta(x: 3, y: 1, precise: true), 3)
        XCTAssertEqual(DockScrollWheelCatcher.delta(x: 0, y: -2, precise: false), -20)
    }

    /// [07 §4] observed: one favorite is 260 wide, two are 126 each with an 8 pt gap.
    func testFavoriteSlotsSplitEvenly() {
        XCTAssertEqual(layout.favoriteSlotFrames(count: 1)[0].width, 260)
        let two = layout.favoriteSlotFrames(count: 2)
        XCTAssertEqual(two.map(\.width), [126, 126])
        XCTAssertEqual(two[1].minX - two[0].maxX, 8)
        let slots = layout.favoriteSlotFrames(count: 4)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(Set(slots.map(\.width)).count, 1)
        XCTAssertEqual(slots[0].minX, layout.favoritesFrame.minX)
        XCTAssertEqual(slots[3].maxX, layout.favoritesFrame.maxX, accuracy: 0.001)
        XCTAssertTrue(layout.favoriteSlotFrames(count: 0).isEmpty)
    }

    /// [06 §12] favorites drop: the pointer maps to the nearest gap 0...count.
    func testFavoriteGapIndex() {
        XCTAssertEqual(SidebarLayout.favoriteGapIndex(forX: 0, count: 3, blockWidth: 300), 0)
        XCTAssertEqual(SidebarLayout.favoriteGapIndex(forX: 140, count: 3, blockWidth: 300), 1)
        XCTAssertEqual(SidebarLayout.favoriteGapIndex(forX: 160, count: 3, blockWidth: 300), 2)
        XCTAssertEqual(SidebarLayout.favoriteGapIndex(forX: 999, count: 3, blockWidth: 300), 3)
        XCTAssertEqual(SidebarLayout.favoriteGapIndex(forX: 10, count: 0, blockWidth: 300), 0)
    }

    /// [07 §12] observed: the hover card is placed at the pointer (+11.5, +5.5), not at the row.
    func testHoverCardAtPointer() {
        let screen = CGRect(x: 0, y: 25, width: 1920, height: 985)
        let card = FloatingBubbleLayout.hoverCard(pointer: CGPoint(x: 330, y: 455), size: CGSize(width: 141.5, height: 42.5), screen: screen)
        XCTAssertEqual(card.origin, CGPoint(x: 341.5, y: 460.5))
    }

    /// Hover delay token. [06 §12] observed ≈ 0.5 s.
    func testHoverDelayToken() {
        XCTAssertEqual(Motion.hoverCardDelay, 0.5)
    }
}
