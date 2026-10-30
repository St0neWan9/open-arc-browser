import XCTest
@testable import OpenArcShell

/// B122: the disabled "Customize Page…" is in the favorite and Today tab menus ([06 §21.5]
/// observed) but not in the pinned tab menu ([05 §右键菜单] observed: Copy Link … Remove Pin).
@MainActor
final class SidebarTabMenuB122Tests: XCTestCase {
    func testCustomizePageOnlyOnFavoritesAndToday() {
        XCTAssertTrue(SidebarTabMenu.showsCustomizePage(.favorite))
        XCTAssertTrue(SidebarTabMenu.showsCustomizePage(.today))
        XCTAssertFalse(SidebarTabMenu.showsCustomizePage(.pinned))
    }
}
