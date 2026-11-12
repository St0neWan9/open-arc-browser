import XCTest
@testable import OpenArcShell

/// Plan B217 (user, 2026-11-12): typing an address that is open in another Space opens it in the
/// current Space; the other Space's tab keeps a "Switch to Tab" row below it.
@MainActor
final class CommandBarOtherSpaceB217Tests: XCTestCase {
    private let here = UUID(), there = UUID()
    private let page = URL(string: "https://example.com/")!

    private func tab(in space: UUID?) -> CommandBarResult {
        CommandBarResult(id: "tab:\(space?.uuidString ?? "fav")", kind: space == nil ? .favoriteTab : .todayTab,
                         title: "Example Domain", url: page, iconHint: .search, spaceID: space,
                         actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()), completion: page.absoluteString)
    }

    private var typed: CommandBarResult {
        CommandBarResult(id: "typed-url", kind: .typedURL, title: "example.com", url: page, iconHint: .globe,
                         actionLabel: "Open", action: .openURL(page, target: .newTab), completion: "example.com")
    }

    private func rank(_ candidates: [CommandBarResult]) -> [CommandBarResultKind] {
        CommandBarRanker.rank(candidates, context: CommandBarQueryContext(text: "example.com", mode: .newTab, currentSpaceID: here))
            .map(\.kind)
    }

    func testTabOfAnotherSpaceDoesNotTakeTheAddress() {
        XCTAssertEqual(rank([tab(in: there), typed]), [.typedURL, .todayTab])
    }

    /// The page is also in the archive of another Space (restoring would go there): the address
    /// still opens here. Seen in the Dev app, where archived copies hid the typed-URL row.
    func testArchivedItemOfAnotherSpaceDoesNotTakeTheAddress() {
        let archived = CommandBarResult(id: "archive:1", kind: .archivedItem, title: "Example Domain", url: page,
                                        iconHint: .search, spaceID: there, actionLabel: "Open",
                                        action: .restoreArchived(itemID: UUID()), completion: page.absoluteString)
        let kinds = rank([tab(in: there), archived, typed])
        XCTAssertEqual(kinds.first, .typedURL)
        XCTAssertTrue(kinds.contains(.todayTab))
        // In this Space's archive it is restored here instead (B66).
        var hereArchived = archived
        hereArchived.spaceID = here
        XCTAssertEqual(rank([hereArchived, typed]), [.archivedItem])
    }

    /// A tab of this Space, or a favorite, is still the one to switch to.
    func testTabOfThisSpaceStillSwitches() {
        XCTAssertEqual(rank([tab(in: here), typed]), [.todayTab])
        XCTAssertEqual(rank([tab(in: nil), typed]), [.favoriteTab])
    }
}
