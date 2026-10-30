import XCTest
import AppKit
import SwiftUI
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// B119: the expanded Little Arc's top bar and round buttons. [06 §21.7] observed: the bar shows
/// only the centered domain (no lock on https, as [06 §17.2] observed for the toolbar); AX lists
/// "Close" and "Enter Full Screen" round buttons, 34 × 33, y 56 / 100. Their spot and showing them
/// on hover are inferred.
@MainActor
final class LittleArcTopBarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeShell(engine: FakeEngine = FakeEngine()) -> ShellModel {
        let shell = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: t0),
            now: { Date(timeIntervalSince1970: 0) }
        )
        addTeardownBlock { @MainActor in shell.stop() }
        return shell
    }

    private func expanded(_ text: String, shell: ShellModel) async -> LittleArcModel {
        let model = LittleArcModel(shell: shell)
        await model.commandBar.waitForRefresh()
        model.commandBar.queryText = text
        await model.commandBar.waitForRefresh()
        model.commandBar.handle(.returnKey)
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .expanded)
        return model
    }

    /// [06 §21.7], [06 §17.2] observed: https shows no lock; plain http keeps the red
    /// struck-through lock of the toolbar (inferred for Little Arc).
    func testNoLockOnSecurePages() {
        XCTAssertFalse(LittleArcTopBar.showsInsecureLock(url: URL(string: "https://swift.org/blog")))
        XCTAssertTrue(LittleArcTopBar.showsInsecureLock(url: URL(string: "http://example.org/")))
        XCTAssertFalse(LittleArcTopBar.showsInsecureLock(url: nil))
    }

    /// The rendered bar for an https page has the domain and no image besides the bar's own
    /// buttons (copy link, Open in, dropdown): no lock glyph. [06 §21.7] observed.
    func testRenderedBarHasNoLockOnHTTPS() async {
        let model = await expanded("https://swift.org/blog", shell: makeShell())
        XCTAssertEqual(model.addressContent, .domain("swift.org", isSecure: true))
        XCTAssertFalse(LittleArcTopBar.showsInsecureLock(url: model.currentURL))
        // The bar lays out at the observed size.
        let host = NSHostingView(rootView: LittleArcTopBar(model: model, palette: model.palette)
            .frame(width: LittleArcTokens.expandedSize.width, height: LittleArcTokens.topBarHeight))
        host.frame = CGRect(x: 0, y: 0, width: LittleArcTokens.expandedSize.width, height: LittleArcTokens.topBarHeight)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, LittleArcTokens.topBarHeight, accuracy: 1)
    }

    /// A plain http page keeps the red struck-through lock (inferred from the toolbar).
    func testInsecureLockOnHTTP() async {
        let model = LittleArcModel(shell: makeShell())
        model.open(URL(string: "http://example.org/")!)
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .expanded)
        XCTAssertTrue(LittleArcTopBar.showsInsecureLock(url: model.currentURL))
    }

    /// [06 §21.7] observed (AX): Close, then Enter Full Screen, 34 × 33, 44 pt apart (y 56 / 100),
    /// the same buttons as Peek's ([06 §22.2]).
    func testRoundButtonsMatchTheAXCapture() {
        XCTAssertEqual(LittleArcWindowButton.allCases.map(\.title), ["Close", "Enter Full Screen"])
        XCTAssertEqual(LittleArcWindowButtonLayout.size, CGSize(width: 34, height: 33))
        XCTAssertEqual(LittleArcWindowButtonLayout.offsets, [0, 44])
        XCTAssertEqual(LittleArcWindowButtonLayout.offsets[1] - LittleArcWindowButtonLayout.offsets[0], 100 - 56)
        // Below the 47 pt bar, so they cover none of its controls (inferred spot).
        XCTAssertGreaterThanOrEqual(LittleArcWindowButtonLayout.topInset, LittleArcTokens.topBarHeight)
    }

    /// Close closes the window and its engine tab, like Escape. [06 §21.7] observed name; action
    /// inferred.
    func testCloseButtonClosesTheWindow() async {
        let engine = FakeEngine()
        let model = await expanded("https://swift.org/blog", shell: makeShell(engine: engine))
        var closed = false
        model.onClose = { closed = true }
        XCTAssertTrue(LittleArcWindowButton.close.isEnabled(on: model))
        LittleArcWindowButton.close.perform(on: model)
        await model.settleEngineWork()
        XCTAssertTrue(closed)
        XCTAssertEqual(model.phase, .closed)
        XCTAssertTrue(engine.tabIDs.isEmpty)
    }

    /// Enter Full Screen moves the page into the main window as a selected Today tab, like Peek's
    /// button of that name ([06 §22.3] observed for Peek; for Little Arc inferred).
    func testEnterFullScreenMovesThePageIntoTheMainWindow() async throws {
        let shell = makeShell()
        let spaceID = try XCTUnwrap(shell.selectedSpaceID)
        let model = await expanded("https://news.ycombinator.com/item", shell: shell)
        XCTAssertTrue(LittleArcWindowButton.enterFullScreen.isEnabled(on: model))
        LittleArcWindowButton.enterFullScreen.perform(on: model)
        await shell.sidebar.settleEngineWork()
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .closed)
        let first = try XCTUnwrap(shell.workspace.today(spaceID: spaceID).first)
        XCTAssertEqual(first.url, URL(string: "https://news.ycombinator.com/item"))
        XCTAssertEqual(shell.selectedTabID, first.id)
    }

    /// Enter Full Screen needs a page: disabled while the window is still the command bar.
    func testEnterFullScreenNeedsAPage() {
        let model = LittleArcModel(shell: makeShell())
        XCTAssertFalse(LittleArcWindowButton.enterFullScreen.isEnabled(on: model))
        XCTAssertTrue(LittleArcWindowButton.close.isEnabled(on: model))
    }
}
