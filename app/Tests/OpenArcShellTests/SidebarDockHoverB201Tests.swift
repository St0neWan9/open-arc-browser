import XCTest
import OpenArcDesign
@testable import OpenArcShell

/// Plan B201: hovering a dock Space icon. Spec: docs/arc-spec/07-design-system.md §4.1 (observed):
/// a ≈ 31 pt rounded fill behind the icon (black ≈ 5 %), the icon in its Space's theme tone, and
/// after ≈ 0.45 s a capsule above it with the Space name and ⌃ number, kept 7 pt inside the sidebar.
@MainActor
final class SidebarDockHoverB201Tests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(SidebarDockHoverTokens.fillSize, 31)
        XCTAssertEqual(SidebarDockHoverTokens.fillOpacity, 0.05)
        XCTAssertEqual(SidebarDockHoverTokens.tooltipDelay, 0.45)
        XCTAssertEqual(Motion.dockSpaceHover.evidence, .inferred)
    }

    /// Centered over the icon, 4 pt above its fill; clamped 7 pt inside the sidebar's edges.
    func testTooltipPlacement() {
        let size = CGSize(width: 100, height: 28)
        let middle = SidebarDockSpaceTooltipLayout.frame(size: size, icon: CGRect(x: 134, y: 9, width: 32, height: 32), sidebarWidth: 300)
        XCTAssertEqual(middle.midX, 150)
        XCTAssertEqual(middle.maxY, 25 - 15.5 - 4, accuracy: 0.001)
        let left = SidebarDockSpaceTooltipLayout.frame(size: CGSize(width: 177, height: 28),
                                                       icon: CGRect(x: 40, y: 9, width: 32, height: 32), sidebarWidth: 357)
        XCTAssertEqual(left.minX, 7, "observed: x 7 for a tag that would start left of the sidebar")
        let right = SidebarDockSpaceTooltipLayout.frame(size: size, icon: CGRect(x: 260, y: 9, width: 32, height: 32), sidebarWidth: 300)
        XCTAssertEqual(right.maxX, 293)
    }

    func testKeysAndWidth() {
        XCTAssertEqual(SidebarDockSpaceTooltipLayout.keys(spaceNumber: 1), ["⌃", "1"])
        XCTAssertEqual(SidebarDockSpaceTooltipLayout.keys(spaceNumber: 9), ["⌃", "9"])
        XCTAssertEqual(SidebarDockSpaceTooltipLayout.keys(spaceNumber: 10), [])
        let bare = SidebarDockSpaceTooltipLayout.width(name: "Work", keys: [])
        let withKeys = SidebarDockSpaceTooltipLayout.width(name: "Work", keys: ["⌃", "1"])
        XCTAssertEqual(withKeys - bare, 8 + 18 * 2 + 4, accuracy: 0.001)
    }
}
