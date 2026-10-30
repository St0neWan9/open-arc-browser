import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B139 (F5-11): "Search <engine> for Image" in the image right-click menu. Spec:
/// docs/arc-spec/05-surfaces.md §右键菜单 E29 (image), observed: Open Image in New Tab · Save
/// Image As… · Capture Image… · Copy Image · Copy Image Address · Search Google for Image ‖
/// Inspect, with "Google" naming the profile's engine. Without Lens we open the engine's
/// search-by-image-URL page in a new tab; engines without one leave the item out (inferred).
@MainActor
final class PageImageSearchB139Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private let image = URL(string: "https://c.example/img/a b.png?w=2&h=3")!

    private func menu(_ target: PageContextMenuTarget) -> PageContextMenu {
        let session = PageContextMenuSession(present: { _ in true }, perform: { _ in }, close: {})
        return PageContextMenu(target: target, items: FakePageContextMenu.items(for: target), session: session)
    }

    private func titles(_ entries: [PageMenuEntry]) -> [String] { entries.map { $0.title ?? "‖" } }

    private func imageTarget(_ source: URL?) -> PageContextMenuTarget {
        PageContextMenuTarget(sourceURL: source, media: .image, hasImageContents: true)
    }

    /// [05 §右键菜单] E29 observed: the item ends the image group, before Inspect.
    func testImageMenuOrderWithImageSearchSpec05ContextMenu() {
        let layout = PageContextMenuLayout(searchEngineName: "Google", imageSearchURLTemplate: SearchEngine.google.imageSearchURLTemplate)
        XCTAssertEqual(titles(layout.entries(for: menu(imageTarget(image)))), [
            "Open Image in New Tab", "Save Image As…", "Capture Image…", "Copy Image", "Copy Image Address",
            "Search Google for Image", "‖", "Inspect",
        ])
    }

    /// The title names the profile's engine ([05 §右键菜单] observed "Search Google" = the engine).
    func testTitleNamesTheProfilesEngine() {
        let layout = PageContextMenuLayout(searchEngineName: "Bing", imageSearchURLTemplate: SearchEngine.bing.imageSearchURLTemplate)
        XCTAssertTrue(titles(layout.entries(for: menu(imageTarget(image)))).contains("Search Bing for Image"))
    }

    /// Engines with no search by image URL leave the item out (inferred), as do images without a
    /// web address (`data:`) or with no source.
    func testItemLeftOutWithoutATemplateOrAWebImage() throws {
        for engine in [SearchEngine.duckDuckGo, .yahoo, .ecosia] {
            XCTAssertNil(engine.imageSearchURLTemplate)
            let layout = PageContextMenuLayout(searchEngineName: engine.displayName, imageSearchURLTemplate: engine.imageSearchURLTemplate)
            XCTAssertFalse(titles(layout.entries(for: menu(imageTarget(image)))).contains { $0.hasSuffix("for Image") })
        }
        let google = PageContextMenuLayout(searchEngineName: "Google", imageSearchURLTemplate: SearchEngine.google.imageSearchURLTemplate)
        let dataImage = try XCTUnwrap(URL(string: "data:image/png;base64,AAAA"))
        for source in [dataImage, nil] {
            XCTAssertFalse(titles(google.entries(for: menu(imageTarget(source)))).contains("Search Google for Image"))
        }
        // A window without the shell action (Little Arc, Peek) does not offer it either.
        let engineOnly = PageContextMenuLayout(searchEngineName: "Google", imageSearchURLTemplate: SearchEngine.google.imageSearchURLTemplate, availableActions: [])
        XCTAssertFalse(titles(engineOnly.entries(for: menu(imageTarget(image)))).contains("Search Google for Image"))
    }

    /// The image's whole URL is one escaped query value of the engine's template (inferred).
    func testSearchURLEscapesTheImageURL() throws {
        let google = try XCTUnwrap(SearchEngine.google.imageSearchURLTemplate)
        XCTAssertEqual(
            PageImageSearch.url(template: google, imageURL: image)?.absoluteString,
            "https://www.google.com/searchbyimage?image_url=https%3A%2F%2Fc.example%2Fimg%2Fa%2520b.png%3Fw%3D2%26h%3D3"
        )
        let bing = try XCTUnwrap(SearchEngine.bing.imageSearchURLTemplate)
        XCTAssertEqual(
            PageImageSearch.url(template: bing, imageURL: try XCTUnwrap(URL(string: "https://c.example/i.png")))?.absoluteString,
            "https://www.bing.com/images/search?view=detailv2&iss=sbi&q=imgurl:https%3A%2F%2Fc.example%2Fi.png"
        )
    }

    /// The window's layout uses the profile's engine and template; choosing the item opens the
    /// results in a new selected tab.
    func testShellLayoutAndActionOpenANewTab() async throws {
        XCTAssertEqual(model.pageMenuLayout.imageSearchURLTemplate, SearchEngine.google.imageSearchURLTemplate)
        let entries = model.pageMenuLayout.entries(for: menu(imageTarget(image)))
        let action = try XCTUnwrap(entries.compactMap { entry -> PageMenuShellAction? in
            if case .shell(let action, "Search Google for Image", true) = entry { return action }
            return nil
        }.first)
        guard case .searchImage(let results) = action else { return XCTFail("expected .searchImage, got \(action)") }

        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://a.example")))
        let tab = try XCTUnwrap(opened)
        model.runPageMenuAction(action, tabID: tab)
        let newID = try XCTUnwrap(model.selectedTabID)
        XCTAssertNotEqual(newID, tab)
        XCTAssertEqual(model.workspace.tabs[newID]?.url, results)

        let profile = try XCTUnwrap(model.sidebar.currentProfileID)
        XCTAssertTrue(model.controller.updateProfileSettings(profile, ProfileSettings(searchEngine: .duckDuckGo)))
        XCTAssertNil(model.pageMenuLayout.imageSearchURLTemplate)
    }
}
