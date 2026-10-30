import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Pins the E27 values of the Create Space button (B112) and the update pill (B111).
/// Spec: docs/arc-spec/07-design-system.md §8.6 (observed values; color rules inferred).
final class SidebarAccessoryTokenTests: XCTestCase {
    private func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
    }

    /// [07 §8.6] observed: no picked color, disabled #A6A8F5 / enabled #2848FB.
    func testCreateButtonFillsWithoutAColor() {
        let none = ThemeStyle(appearance: .light, colors: [])
        XCTAssertEqual(CreateSpaceButtonTokens.fill(for: none, isEnabled: false, systemAppearance: .light), RGBAColor(hex: 0xA6A8F5))
        XCTAssertEqual(CreateSpaceButtonTokens.fill(for: none, isEnabled: true, systemAppearance: .light), RGBAColor(hex: 0x2848FB))
    }

    /// [07 §8.6] observed: orange preset p1-5 disabled ≈ #D88E64 (inferred rule, ≤ 6/255).
    func testCreateButtonDisabledFillFollowsTheTheme() {
        let orange = ThemeStyle(appearance: .light, colors: [RGBAColor(hex: 0xFF8558)])
        let fill = CreateSpaceButtonTokens.fill(for: orange, isEnabled: false, systemAppearance: .light)
        XCTAssertLessThanOrEqual(distance(fill, RGBAColor(hex: 0xD88E64)), 6)
    }

    /// [07 §8.6] observed: x 8–268, ≈ 22 pt, sage #6C9174 → #7D9C84.
    func testUpdatePillTokens() {
        XCTAssertEqual(UpdatePillTokens.height, 22)
        XCTAssertEqual(UpdatePillTokens.horizontalInset, 8)
        XCTAssertLessThanOrEqual(distance(UpdatePillTokens.fill(over: RGBAColor(hex: 0x6C9174)), RGBAColor(hex: 0x7D9C84)), 1.5)
    }
}
