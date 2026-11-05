import XCTest
import AppKit
@testable import OpenArcShell

/// B172: the icon picker's layout and content (2× Arc captures).
@MainActor
final class IconPickerB172Tests: XCTestCase {
    /// The Icon page is a full 8 × 7 grid of symbols that exist on the minimum OS.
    func testIconPageIsAFullGrid() {
        XCTAssertEqual(IconPickerCatalog.symbols.count, IconPickerTokens.columns * 7)
        XCTAssertEqual(Set(IconPickerCatalog.symbols).count, IconPickerCatalog.symbols.count)
        for name in IconPickerCatalog.symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    /// The category bar has eight items, one per grid column.
    func testEmojiCategories() {
        XCTAssertEqual(IconPickerCatalog.emoji.count, IconPickerTokens.columns)
        for group in IconPickerCatalog.emoji {
            XCTAssertNotNil(NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil), group.symbol)
            XCTAssertFalse(group.emoji.isEmpty)
            XCTAssertEqual(Set(group.emoji).count, group.emoji.count, group.symbol)
        }
    }

    func testEmojiSearchUsesUnicodeNames() {
        XCTAssertTrue(IconPickerCatalog.search("rocket").contains("🚀"))
        XCTAssertTrue(IconPickerCatalog.search("  ").isEmpty)
    }
}
