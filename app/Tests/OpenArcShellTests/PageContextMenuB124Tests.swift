import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B124: the web page's right-click menu. Spec: docs/arc-spec/05-surfaces.md §右键菜单,
/// "网页内容右键菜单 (E29)" (observed items and order for the page, a link, an image, a selection
/// and an editable field; "Search Google" names the profile's search engine). Items the shell
/// leaves out in v1 (Cast…, Search Google for Image, Services ▸, AutoFill ▸) are listed in
/// PageContextMenuLayout.swift.
@MainActor
final class PageContextMenuB124Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private var spaceID: UUID!
    private let now = Date(timeIntervalSince1970: 0)

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory()),
            workspace: .demo(now: now),
            now: { Date(timeIntervalSince1970: 0) }
        )
        spaceID = try XCTUnwrap(model.selectedSpaceID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private let layout = PageContextMenuLayout(searchEngineName: "Google")

    /// A fake menu for `target` with the engine items a Chromium-like engine offers.
    private func menu(_ target: PageContextMenuTarget, extra: [PageContextMenuItem] = []) -> PageContextMenu {
        let session = PageContextMenuSession(present: { _ in true }, perform: { _ in }, close: {})
        return PageContextMenu(target: target, items: FakePageContextMenu.items(for: target) + extra, session: session)
    }

    /// Titles with "‖" for separators.
    private func titles(_ entries: [PageMenuEntry]) -> [String] {
        entries.map { $0.title ?? "‖" }
    }

    // MARK: Order ([05 §右键菜单] E29 observed)

    func testPageMenuOrder() {
        let entries = layout.entries(for: menu(PageContextMenuTarget(pageURL: URL(string: "https://a.example"))))
        XCTAssertEqual(titles(entries), [
            "Back", "Forward", "Reload", "‖", "Save As…", "Print…", "‖", "View Page Source", "Inspect",
        ])
        // Back / Forward are disabled without history ([05 §右键菜单] observed).
        guard case .engine(let back) = entries[0] else { return XCTFail("Back is the engine's") }
        XCTAssertFalse(back.isEnabled)
    }

    func testPageMenuTranslateItemComesAfterPrint() {
        let translate = PageContextMenuItem(id: 77, role: .translate, title: "Translate to English")
        let entries = layout.entries(for: menu(PageContextMenuTarget(), extra: [translate]))
        XCTAssertEqual(Array(titles(entries)[4...6]), ["Save As…", "Print…", "Translate to English"])
        guard case .shell(.translate, _, _) = entries[6] else { return XCTFail("Translate is run by the shell") }
    }

    func testLinkMenuOrder() throws {
        let link = try url("https://b.example/next")
        let entries = layout.entries(for: menu(PageContextMenuTarget(linkURL: link, linkText: "next")))
        XCTAssertEqual(titles(entries), [
            "Open Link in New Tab", "Open Link in New Window", "Open Link in Split View", "Open Link in Little Arc",
            "Open Link in Incognito Window", "‖", "Save Link As…", "Copy Link Address", "‖", "Inspect",
        ])
        XCTAssertTrue(entries.contains(.shell(.openLinkInSplitView(link), title: "Open Link in Split View", isEnabled: true)))
        XCTAssertTrue(entries.contains(.shell(.openLinkInIncognito(link), title: "Open Link in Incognito Window", isEnabled: true)))
    }

    func testLinkWithSelectionAddsCopyAndSearch() throws {
        let target = PageContextMenuTarget(linkURL: try url("https://b.example"), linkText: "next", selectionText: "next")
        let names = titles(layout.entries(for: menu(target)))
        let copy = try XCTUnwrap(names.firstIndex(of: "Copy"))
        XCTAssertEqual(Array(names[copy...(copy + 3)]), ["Copy", "Copy Link to Highlight", "Search Google for “next”", "Print…"])
    }

    func testImageMenuOrder() {
        let target = PageContextMenuTarget(sourceURL: URL(string: "https://c.example/i.png"), media: .image, hasImageContents: true)
        XCTAssertEqual(titles(layout.entries(for: menu(target))), [
            "Open Image in New Tab", "Save Image As…", "Capture Image…", "Copy Image", "Copy Image Address", "‖", "Inspect",
        ])
    }

    func testSelectionMenuOrderUsesTheProfilesEngine() {
        let target = PageContextMenuTarget(selectionText: "word")
        let bing = PageContextMenuLayout(searchEngineName: "Bing")
        XCTAssertEqual(titles(bing.entries(for: menu(target))), [
            "Look Up “word”", "Search Bing for “word”", "Copy", "Copy Link to Highlight", "Print…", "‖", "Inspect", "‖", "Speech",
        ])
    }

    func testEditableMenuOrder() {
        let target = PageContextMenuTarget(selectionText: "word", isEditable: true, editFlags: [.canCopy, .canPaste])
        XCTAssertEqual(titles(layout.entries(for: menu(target))), [
            "Look Up “word”", "Search Google for “word”", "‖", "Emoji & Symbols", "Import Passwords", "‖", "Undo", "Redo", "‖",
            "Cut", "Copy", "Paste", "Paste and Match Style", "Select All", "‖", "Print…", "‖", "Language Settings",
            "Writing Direction", "‖", "Inspect", "‖", "Speech",
        ])
    }

    func testExtensionItemsGoBeforeInspect() {
        let ext = PageContextMenuItem(id: 51000, role: .extension, title: "Save to Notes", extensionID: "abc")
        let names = titles(layout.entries(for: menu(PageContextMenuTarget(), extra: [ext])))
        XCTAssertEqual(Array(names.suffix(5)), ["‖", "Save to Notes", "‖", "View Page Source", "Inspect"])
    }

    func testLongSelectionIsShortened() {
        let long = String(repeating: "a", count: 80)
        let names = titles(layout.entries(for: menu(PageContextMenuTarget(selectionText: long))))
        XCTAssertEqual(names[1], "Search Google for “\(String(repeating: "a", count: 50))…”")
    }

    func testNoDoubleOrEdgeSeparators() throws {
        let targets = [
            PageContextMenuTarget(), PageContextMenuTarget(linkURL: try url("https://x.example")),
            PageContextMenuTarget(media: .image), PageContextMenuTarget(selectionText: "x"),
            PageContextMenuTarget(isEditable: true),
        ]
        for target in targets {
            let entries = layout.entries(for: menu(target))
            XCTAssertNotEqual(entries.first, .separator)
            XCTAssertNotEqual(entries.last, .separator)
            for (a, b) in zip(entries, entries.dropFirst()) { XCTAssertFalse(a == .separator && b == .separator) }
        }
    }

    func testIncognitoWindowOffersNoLittleArcOrImport() throws {
        var layout = self.layout
        layout.availableActions.subtract([.openLinkInLittleArc, .importPasswords])
        let names = titles(layout.entries(for: menu(PageContextMenuTarget(linkURL: try url("https://x.example")))))
        XCTAssertFalse(names.contains("Open Link in Little Arc"))
    }

    // MARK: Shell actions

    func testOpenLinkInSplitViewMakesASplitWithTheLink() async throws {
        let opened = try await model.openNewTab(url: try url("https://a.example"))
        let source = try XCTUnwrap(opened)
        let link = try url("https://b.example/next")
        model.runPageMenuAction(.openLinkInSplitView(link), tabID: source)
        let newID = try XCTUnwrap(model.selectedTabID)
        XCTAssertNotEqual(newID, source)
        XCTAssertEqual(model.workspace.tabs[newID]?.url, link)
        let split = try XCTUnwrap(model.workspace.splits.values.first { $0.root.tabIDs.contains(source) })
        XCTAssertEqual(Set(split.root.tabIDs), [source, newID])
        // The link's tab sits right after its page in Today.
        let today = model.workspace.today(spaceID: spaceID).map(\.id)
        XCTAssertEqual(today.firstIndex(of: newID), today.firstIndex(of: source).map { $0 + 1 })
    }

    func testOpenLinkInLittleArcAndIncognito() async throws {
        var littleArcs: [UUID] = []
        var windows: [BrowserWindowRequest] = []
        model.controller.openLittleArcWindow = { littleArcs.append($0) }
        model.controller.openBrowserWindow = { windows.append($0) }
        let opened = try await model.openNewTab(url: try url("https://a.example"))
        let tab = try XCTUnwrap(opened)
        let link = try url("https://b.example/next")
        model.runPageMenuAction(.openLinkInLittleArc(link), tabID: tab)
        XCTAssertEqual(littleArcs.count, 1)
        XCTAssertEqual(model.controller.takeLittleArcLaunchURL(for: littleArcs[0]), link)
        model.runPageMenuAction(.openLinkInIncognito(link), tabID: tab)
        XCTAssertEqual(windows.map(\.kind), [.incognito])
        XCTAssertEqual(windows.first?.url, link)
    }

    func testIncognitoWindowRequestWithURLOpensTheLink() throws {
        let link = try url("https://b.example/next")
        let window = ShellModel.window(for: BrowserWindowRequest(kind: .incognito, url: link), on: model.controller)
        defer { window.stop() }
        XCTAssertTrue(window.isIncognito)
        let selected = try XCTUnwrap(window.selectedTabID)
        XCTAssertEqual(window.workspace.tabs[selected]?.url, link)
    }

    func testSearchOpensATabWithTheProfilesEngine() async throws {
        let opened = try await model.openNewTab(url: try url("https://a.example"))
        let tab = try XCTUnwrap(opened)
        model.runPageMenuAction(.search("open arc"), tabID: tab)
        let newID = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(model.workspace.tabs[newID]?.url?.absoluteString, "https://www.google.com/search?q=open%20arc")
    }

    func testCaptureImageStartsRegionCapture() async throws {
        let opened = try await model.openNewTab(url: try url("https://a.example"))
        let tab = try XCTUnwrap(opened)
        try await waitUntil { self.model.selectedLiveTab != nil }
        model.runPageMenuAction(.captureImage, tabID: tab)
        XCTAssertEqual(model.pageCapture.phase, .selecting)
        model.pageCapture.cancel()
    }

    // MARK: Routing

    func testEngineMenuReachesTheWindowAndClosesWithoutOne() async throws {
        let opened = try await model.openNewTab(url: try url("https://a.example"))
        let id = try XCTUnwrap(opened)
        try await waitUntil { self.model.sidebar.liveTab(for: id) != nil }
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        // Not on screen in any window: the session closes unshown.
        model.sidebar.countsAsVisibleWindow = false
        let hidden = live.simulateContextMenu(PageContextMenuTarget())
        try await waitUntil { hidden.isClosed }
        XCTAssertTrue(hidden.presented.isEmpty)
    }

    func testSessionRunsItemsOnlyUntilClosed() {
        let recorder = FakePageContextMenuRecorder()
        let session = PageContextMenuSession(
            present: { _ in true }, perform: { recorder.notePerformed($0) }, close: { recorder.noteClosed() }
        )
        session.perform(7)
        session.close()
        session.perform(8)
        session.close()
        XCTAssertEqual(recorder.performed, [7])
        XCTAssertTrue(recorder.isClosed)
        XCTAssertFalse(session.present(NSObject()))
    }

    // MARK: Extension action menu (B116 + B124)

    func testActionMenuListsTheExtensionsOwnItems() async throws {
        let opened = try await model.openNewTab(url: try url("https://site.example"))
        let tabID = try XCTUnwrap(opened)
        try await waitUntil { self.model.sidebar.liveTab(for: tabID) != nil }
        let profile = try XCTUnwrap(model.sidebar.currentProfileID)
        let extensions = engine.fakeExtensionService
        extensions.simulateActionMenuItems([PageContextMenuItem(id: 51001, role: .extension, title: "Options page", extensionID: "pop")],
                                           extensionID: "pop")
        extensions.simulateInstalled(EngineExtensionInfo(id: "pop", name: "Pop", hasPopup: true), profileID: profile)
        let sc = model.siteControls
        sc.present()
        try await waitUntil { sc.extensionOwnMenuItems(for: "pop").count == 1 }
        XCTAssertEqual(sc.extensionOwnMenuItems(for: "pop").map(\.title), ["Options page"])
        XCTAssertEqual(sc.extensionMenuItems(for: "pop"), [.manage, .remove])
        sc.performExtensionOwnMenuItem(51001, extensionID: "pop")
        await sc.settle()
        let engineTab = try XCTUnwrap(model.sidebar.liveTab(for: tabID)?.id)
        XCTAssertEqual(extensions.actionMenuItemsRun, ["pop#51001@\(engineTab)"])
        XCTAssertFalse(sc.isPresented)
    }
}
