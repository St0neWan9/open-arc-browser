import Foundation
import AppKit
import SwiftUI
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Records every default-browser change; never touches LaunchServices.
@MainActor
private final class FakeDefaultBrowserService: DefaultBrowserService {
    var handlers: [String: URL] = [:]
    var setCalls: [(app: URL, scheme: String)] = []
    /// Schemes whose change is refused (the user declined).
    var refusedSchemes: Set<String> = []
    let applicationURL = URL(fileURLWithPath: "/Applications/Open Arc.app", isDirectory: true)

    struct Refused: Error {}

    func defaultApplication(toOpen url: URL) -> URL? { url.scheme.flatMap { handlers[$0] } }

    func setDefaultApplication(at appURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        setCalls.append((appURL, scheme))
        if refusedSchemes.contains(scheme) { throw Refused() }
        handlers[scheme] = appURL
    }
}

/// D2: links and files opened from other apps, and the default-browser setting.
/// Spec: [03 §账号卡] observed "Arc isn’t your default browser" + "Make Arc your default";
/// [01 §Arc] observed "Set as Default Browser". Routing of external links (a new Today tab at the
/// top of the current Space of the frontmost window, a window opened when none is) is inferred.
@MainActor
final class OpenURLTests: XCTestCase {
    private func makeController(_ f: SidebarFixture = SidebarFixture(), defaultBrowser: (any DefaultBrowserService)? = nil) -> WorkspaceController {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), defaultBrowser: defaultBrowser)
        var counter = 1_000
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private let link = URL(string: "https://mail-link.example.com/article")!

    // MARK: Routing

    /// A link opens as a new Today tab at the top of the frontmost window's current Space and is
    /// selected; the window is brought to the front. [D2] inferred.
    func testURLOpensTodayTabInFrontmostWindowsCurrentSpace() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let back = window(controller, space: f.home)
        let front = window(controller, space: f.work)
        front.windowDidBecomeKey()
        var focused = 0
        front.focusWindow = { focused += 1 }

        controller.openExternal([link])

        let id = try XCTUnwrap(front.selectedTabID)
        XCTAssertEqual(controller.workspace.today(spaceID: f.work).first?.id, id, "top of Today")
        XCTAssertEqual(controller.workspace.tabs[id]?.url, link)
        XCTAssertEqual(controller.workspace.tabs[id]?.title, "mail-link.example.com")
        XCTAssertEqual(front.selectedSpaceID, f.work)
        XCTAssertNil(back.selectedTabID, "the other window is untouched")
        XCTAssertEqual(focused, 1)
    }

    /// The window leaves the Library and closes the command bar so the new tab is on screen.
    func testURLLeavesLibraryAndCommandBar() {
        let f = SidebarFixture()
        let controller = makeController(f)
        let model = window(controller, space: f.home)
        model.library.openDefault()
        model.presentCommandBar(.newTab)
        controller.openExternal([link])
        XCTAssertNil(model.library.section)
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.workspace.tabs[model.selectedTabID ?? UUID()]?.url, link)
    }

    /// A local HTML or PDF file opens like a link, titled with its file name; other files and
    /// schemes are ignored (Info.plist declares only http/https and HTML/PDF documents).
    func testFileURLOpensAndUnsupportedURLsAreIgnored() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let model = window(controller, space: f.home)
        let before = controller.workspace.today(spaceID: f.home).count
        let pdf = URL(fileURLWithPath: "/tmp/Report.pdf")

        controller.openExternal([URL(string: "ftp://files.example.com/x")!, URL(fileURLWithPath: "/tmp/notes.txt"), pdf])

        let id = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(controller.workspace.tabs[id]?.url, pdf)
        XCTAssertEqual(controller.workspace.tabs[id]?.title, "Report.pdf")
        XCTAssertEqual(controller.workspace.today(spaceID: f.home).count, before + 1, "only the PDF opened")
        XCTAssertTrue(ExternalOpen.accepts(URL(fileURLWithPath: "/tmp/page.HTML")))
        XCTAssertFalse(ExternalOpen.accepts(URL(string: "mailto:someone@example.com")!))
    }

    /// Several URLs at once open in the order given; the last one ends up on top and selected.
    func testMultipleURLsOpenInOrder() {
        let f = SidebarFixture()
        let controller = makeController(f)
        let model = window(controller, space: f.home)
        let urls = (1...3).map { URL(string: "https://site\($0).example.com")! }

        controller.openExternal(urls)

        let today = controller.workspace.today(spaceID: f.home).compactMap(\.url)
        XCTAssertEqual(Array(today.prefix(3)), urls.reversed(), "each new tab goes to the top")
        XCTAssertEqual(model.workspace.tabs[model.selectedTabID ?? UUID()]?.url, urls.last)
    }

    /// No browser window: one window is requested (once, even for several deliveries), and the
    /// URLs open in it when it registers.
    func testNoWindowRequestsOneAndOpensThere() {
        let f = SidebarFixture()
        let controller = makeController(f)
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        let first = URL(string: "https://first.example.com")!

        controller.openExternal([first])
        controller.openExternal([link])
        XCTAssertEqual(requests.map(\.kind), [.restore])

        let model = window(controller, space: f.work)
        let today = controller.workspace.today(spaceID: f.work).compactMap(\.url)
        XCTAssertEqual(Array(today.prefix(2)), [link, first])
        XCTAssertEqual(model.workspace.tabs[model.selectedTabID ?? UUID()]?.url, link)
        XCTAssertTrue(controller.pendingExternalURLs.isEmpty)
    }

    /// Links that arrive before the scene exists (the link that launched the app) are kept by the
    /// inbox and delivered in order once the controller connects.
    func testInboxBuffersUntilConnected() {
        let inbox = ExternalOpenInbox()
        let a = URL(string: "https://a.example.com")!, b = URL(string: "https://b.example.com")!
        inbox.receive([a])
        inbox.receive([b])
        var delivered: [[URL]] = []
        inbox.connect { delivered.append($0) }
        inbox.receive([link])
        XCTAssertEqual(delivered, [[a, b], [link]])
    }

    /// A link that launched the app with no window appearing gets one window, once; nothing is
    /// opened when the controller already took the links.
    func testInboxOpensFallbackWindowOnlyWhileWaiting() {
        let inbox = ExternalOpenInbox()
        var opened = 0
        inbox.fallbackWindowOpener = { opened += 1 }
        inbox.openWindowIfStillWaiting()
        XCTAssertEqual(opened, 0, "nothing waiting")
        inbox.receive([link])
        inbox.openWindowIfStillWaiting()
        inbox.openWindowIfStillWaiting()
        XCTAssertEqual(opened, 1)
        var delivered: [URL] = []
        inbox.connect { delivered += $0 }
        XCTAssertEqual(delivered, [link])
        XCTAssertFalse(inbox.isWaiting)
    }

    /// B19 (cold start): the commands that install the window openers must have a body SwiftUI
    /// evaluates. A body of only `EmptyCommands()` was skipped, so a link that launched the app
    /// found no opener and no window came. Evaluating the body installs all three openers.
    func testExternalOpenCommandsInstallOpeners() {
        let inbox = ExternalOpenInbox()
        let controller = makeController()
        XCTAssertNil(inbox.fallbackWindowOpener)
        let commands = ExternalOpenCommands(inbox: inbox, controller: controller)
        let body = commands.body
        XCTAssertNotNil(inbox.fallbackWindowOpener)
        XCTAssertNotNil(controller.openLittleArcWindow)
        XCTAssertNotNil(controller.openBrowserWindow)
        XCTAssertFalse(type(of: body) == EmptyCommands.self, "SwiftUI skips a body that is only EmptyCommands")
    }

    /// An incognito window never takes external links; the frontmost normal window does.
    func testIncognitoWindowIsSkipped() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let normal = window(controller, space: f.home)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        incognito.windowDidBecomeKey()

        controller.openExternal([link])

        XCTAssertNil(incognito.selectedTabID)
        XCTAssertEqual(normal.workspace.tabs[try XCTUnwrap(normal.selectedTabID)]?.url, link)
    }

    /// The Air Traffic Control hook (E5): a router can send a link to another Space.
    func testRouterHookCanPickASpace() throws {
        struct ToWork: ExternalLinkRouting {
            let work: UUID
            func destination(for url: URL, in workspace: WorkspaceState) -> ExternalOpenDestination { .space(work) }
        }
        let f = SidebarFixture()
        let controller = makeController(f)
        controller.externalLinkRouter = ToWork(work: f.work)
        let model = window(controller, space: f.home)

        controller.openExternal([link])

        XCTAssertEqual(model.selectedSpaceID, f.work)
        XCTAssertEqual(controller.workspace.today(spaceID: f.work).first?.url, link)
    }

    // MARK: Default browser [03 §账号卡, 01 §Arc]

    /// The status reads the handler of an http URL: not default until the app is registered.
    func testDefaultBrowserStatusReadsHandler() {
        let fake = FakeDefaultBrowserService()
        fake.handlers["http"] = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let model = DefaultBrowserModel(service: fake, notificationCenter: NotificationCenter())
        XCTAssertFalse(model.isDefault)
        XCTAssertEqual(model.statusText, "Open Arc isn’t your default browser")

        fake.handlers["http"] = fake.applicationURL
        model.refresh()
        XCTAssertTrue(model.isDefault)
    }

    /// The status is read again when the app becomes active (changed in System Settings).
    func testDefaultBrowserStatusRefreshesOnActivation() {
        let fake = FakeDefaultBrowserService()
        let center = NotificationCenter()
        let model = DefaultBrowserModel(service: fake, notificationCenter: center)
        XCTAssertFalse(model.isDefault)
        fake.handlers["http"] = fake.applicationURL
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(model.isDefault)
    }

    /// "Make Open Arc your default" / "Set as Default Browser" registers the app for http and
    /// https, then shows it as the default.
    func testMakeDefaultRegistersHTTPAndHTTPS() async {
        let fake = FakeDefaultBrowserService()
        let model = DefaultBrowserModel(service: fake, notificationCenter: NotificationCenter())
        await model.makeDefault()
        XCTAssertEqual(fake.setCalls.map(\.scheme), ["http", "https"])
        XCTAssertTrue(fake.setCalls.allSatisfy { $0.app == fake.applicationURL })
        XCTAssertTrue(model.isDefault)
        XCTAssertFalse(model.isRequesting)
        XCTAssertNil(model.lastError)
    }

    /// A refusal stops the request and keeps the "isn’t your default" state.
    func testMakeDefaultRefused() async {
        let fake = FakeDefaultBrowserService()
        fake.refusedSchemes = ["http"]
        let model = DefaultBrowserModel(service: fake, notificationCenter: NotificationCenter())
        await model.makeDefault()
        XCTAssertEqual(fake.setCalls.map(\.scheme), ["http"])
        XCTAssertFalse(model.isDefault)
        XCTAssertNotNil(model.lastError)
    }

    /// Settings reaches the same model through the controller, and the button is live.
    func testSettingsUsesInjectedService() async {
        let fake = FakeDefaultBrowserService()
        let controller = makeController(defaultBrowser: fake)
        let shell = controller.appHost()
        let settings = SettingsModel(shell: shell)
        XCTAssertTrue(settings.defaultBrowser === controller.defaultBrowser)
        XCTAssertTrue(SettingsCatalog.control("account.makeDefault").isEnabled)
        await settings.defaultBrowser.makeDefault()
        XCTAssertEqual(fake.handlers["https"], fake.applicationURL)
        XCTAssertTrue(settings.defaultBrowser.isDefault)
    }

    /// Without an injected service the dependencies use the in-memory one, never LaunchServices.
    func testDefaultDependenciesNeverTouchTheSystem() {
        XCTAssertTrue(AppDependencies.fake().defaultBrowser is InMemoryDefaultBrowserService)
    }
}
