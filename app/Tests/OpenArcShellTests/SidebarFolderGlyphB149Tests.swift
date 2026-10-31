import XCTest
import SwiftUI
import OpenArcDesign
@testable import OpenArcShell

/// B149: the closed folder glyph is drawn at Arc's size (2× capture of 12 closed folders: ink
/// fills the 18 pt icon cell, ≈ 1.5 pt outline), not the 22.5 pt wide open-folder box.
/// Spec: [07 §4] folder row (B149 values to be added there).
@MainActor
final class SidebarFolderGlyphB149Tests: XCTestCase {
    func testClosedFolderInkFillsTheIconCell_07_4() {
        let box = SidebarFolderGlyph.inkBox(isExpanded: false)
        XCTAssertEqual(box, CGSize(width: 18, height: 18))
        XCTAssertEqual(box.width, CGFloat(Metrics.Sidebar.rowIconSize), "same box as a favicon (x 17–35)")
        XCTAssertLessThan(box.width, SidebarFolderGlyph.inkBox(isExpanded: true).width)
        XCTAssertEqual(Metrics.Sidebar.closedFolderStroke, 1.5)
    }

    func testOpenFolderKeepsTheMeasuredBox_07_4() {
        XCTAssertEqual(SidebarFolderGlyph.inkBox(isExpanded: true), CGSize(width: 22.5, height: 16.5))
    }

    /// The outline's stroke centers sit half a stroke inside the box, so the ink spans the box.
    func testClosedOutlineInksTheWholeBox_07_4() {
        let rect = CGRect(x: 0, y: 0, width: 18, height: 18)
        let outline = SidebarClosedFolderShape(part: .outline).path(in: rect)
        let half = CGFloat(Metrics.Sidebar.closedFolderStroke) / 2
        let inked = outline.boundingRect.insetBy(dx: -half, dy: -half)
        XCTAssertEqual(inked.minX, 0, accuracy: 0.01)
        XCTAssertEqual(inked.maxX, 18, accuracy: 0.01)
        XCTAssertEqual(inked.minY, 0, accuracy: 0.01)
        XCTAssertEqual(inked.maxY, 18, accuracy: 0.01)
        let band = SidebarClosedFolderShape(part: .tabBand).path(in: rect).boundingRect
        XCTAssertLessThan(band.maxY, 6, "the tab band stays above the flap line")
    }

    /// The glyph ink is lighter than the title: ≈ 70 % of its contrast. B149 observed.
    func testFolderInkOpacity_07_4() {
        XCTAssertEqual(SidebarLocalTokens.folderGlyphInkOpacity, 0.7, accuracy: 0.001)
    }
}
