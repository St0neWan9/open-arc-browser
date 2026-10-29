import XCTest
@testable import OpenArcModel

/// `TreeOps.deleteTheme`: tombstones a theme no live Space shows (used when the first-launch Space
/// is dropped for the account's Spaces; a user decision, 2026-10-28).
final class TreeOpsDeleteThemeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let profile = UUID(), space = UUID(), theme = UUID()

    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "Default", now: t0)
        s = TreeOps.createTheme(s, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x123456)]), now: t0)
        return try TreeOps.createSpace(s, id: space, profileID: profile, name: "Home", themeID: theme, now: t0)
    }

    func testRefusedWhileALiveSpaceShowsIt() throws {
        let s = try base()
        XCTAssertThrowsError(try TreeOps.deleteTheme(s, id: theme, now: t0.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? TreeError, .themeInUse(theme))
        }
    }

    func testTombstonesOnceTheSpaceIsGone() throws {
        var s = try TreeOps.deleteSpace(try base(), id: space, now: t0.addingTimeInterval(1))
        s = try TreeOps.deleteTheme(s, id: theme, now: t0.addingTimeInterval(2))
        let deleted = try XCTUnwrap(s.themes[theme])
        XCTAssertTrue(deleted.meta.isTombstone, "deleted by tombstoning, never removed")
        XCTAssertEqual(deleted.meta.deletedAt, t0.addingTimeInterval(2))
        XCTAssertEqual(deleted.colors, [RGBAColor(hex: 0x123456)], "no field changes")
        XCTAssertThrowsError(try TreeOps.deleteTheme(s, id: theme, now: t0.addingTimeInterval(3))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(theme))
        }
        XCTAssertThrowsError(try TreeOps.deleteTheme(s, id: UUID(), now: t0))
    }
}
