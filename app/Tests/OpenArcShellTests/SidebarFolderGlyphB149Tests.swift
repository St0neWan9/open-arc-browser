import XCTest
import SwiftUI
import OpenArcModel
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
        let open = SidebarFolderGlyph.inkBox(isExpanded: true)
        XCTAssertEqual(open, CGSize(width: 22.5, height: 16.5))
        let rect = CGRect(origin: .zero, size: open)
        let half = CGFloat(Metrics.Sidebar.closedFolderStroke) / 2
        for part in [SidebarOpenFolderShape.Part.front, .backOutline] {
            let inked = SidebarOpenFolderShape(part: part).path(in: rect).boundingRect.insetBy(dx: -half, dy: -half)
            XCTAssertGreaterThanOrEqual(inked.minX, -0.01)
            XCTAssertLessThanOrEqual(inked.maxX, open.width + 0.01)
            XCTAssertLessThanOrEqual(inked.maxY, open.height + 0.01)
        }
    }

    /// B170: the three glyph colors follow the window, within 8/255 of the 2× Arc capture.
    func testFolderColorsMatchTheCaptures() {
        func close(_ a: RGBAColor, _ hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
            let b = RGBAColor(hex: hex)
            let far = max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
            XCTAssertLessThan(far, 8.0 / 255, "\(a) vs \(String(hex, radix: 16))", file: file, line: line)
        }
        let green = ThemeDerivation.folderGlyphColors(window: RGBAColor(hex: 0x6B9074), lightInk: true)
        close(green.outline, 0xEDFEEF); close(green.back, 0x64A574); close(green.body, 0x396642)
        let light = ThemeDerivation.folderGlyphColors(window: RGBAColor(hex: 0xF0ECE8), lightInk: false)
        close(light.outline, 0x675345); close(light.back, 0xD2BAA2); close(light.body, 0xF3EEEA)
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
