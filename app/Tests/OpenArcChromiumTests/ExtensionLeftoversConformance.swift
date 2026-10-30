import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B116 (F4 #10, extension leftovers) in the real engine, run from
/// `testChromiumEngineConformance`. A sample MV3 extension (written to a temporary folder and
/// loaded unpacked) calls, from its own page in a tab, the APIs that need browser chrome. The
/// expected outcomes are the decisions recorded for B116; Arc's behavior for them is not in the
/// spec (`docs/arc-spec/06-flows.md §12` records only the Site Control Center's "Extensions"
/// section, observed):
/// - `chrome.contextMenus.create` succeeds (Chromium's menu manager keeps the item), but no page
///   menu shows it yet: the bridge shows no page context menu at all (needs a bridge patch).
/// - `chrome.windows.get*` finds no window (needs a Chromium patch).
/// - `chrome.action.openPopup()` fails (needs a Chromium patch).
/// - `chrome.sidePanel.open()` fails; side panels stay out of v1.
/// Every call settles (none hangs) within its timeout.
extension ChromiumEngineConformanceTests {
    @MainActor
    func checkExtensionLeftovers(_ engine: ChromiumEngine, dataDirectory: URL, profileID: UUID) async throws {
        let folder = try SampleLeftoversExtension.write(into: dataDirectory)
        let extensionID = try await engine.extensions.loadUnpacked(folder, profileID: profileID)
        XCTAssertEqual(extensionID.count, 32)

        let page = try XCTUnwrap(URL(string: "chrome-extension://\(extensionID)/probe.html"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID, initialURL: page))
        try await waitForState(tab) { $0.title == "B116 probe" && !$0.loadState.isLoading }
        let json = try await tab.evaluateJavaScript(SampleLeftoversExtension.probeScript)
        let results = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String], "probe returned \(json)"
        )
        let report = results.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        print("B116 probe: \(report)")

        XCTAssertEqual(results["contextMenusCreate"], "ok", report)
        for key in ["windowsGetCurrent", "windowsGetLastFocused", "actionOpenPopup", "sidePanelOpen"] {
            let outcome = try XCTUnwrap(results[key], key)
            XCTAssertTrue(outcome.hasPrefix("error:"), "\(key): \(outcome)")
        }
        XCTAssertEqual(results["windowsGetAll"], "ok:[]", report)

        // B124: the page's right-click menu carries the extension's `page` item, and choosing it
        // reaches `contextMenus.onClicked` in the extension's service worker.
        try await checkPageContextMenu(engine, tab: tab, extensionID: extensionID)

        await engine.closeTab(tab.id)
        await engine.extensions.uninstall(extensionID, profileID: profileID)
    }

    /// Plan B124 ([05 §右键菜单] E29 observed menus): a right-click on the extension's probe page
    /// sends `.contextMenuRequested` with Chromium's page items (Back, Reload, View Page Source,
    /// Inspect…) and the sample extension's "B116 item"; performing that item fires the
    /// extension's `contextMenus.onClicked` (it records the click in `chrome.storage.session`).
    /// The same item is listed for the action (`contexts: ["action"]`).
    @MainActor
    func checkPageContextMenu(_ engine: ChromiumEngine, tab: any BrowserTab, extensionID: String) async throws {
        let chromiumTab = try XCTUnwrap(tab as? ChromiumTab)
        let events = tab.events()
        let menu = try await withTimeout(seconds: 20) { () -> PageContextMenu? in
            await chromiumTab.requestContextMenu(x: 40, y: 40)
            for await event in events { if case .contextMenuRequested(let menu) = event { return menu } }
            return nil
        }
        let page = try XCTUnwrap(menu, "no context menu")
        let roles = Set(page.items.map(\.role))
        print("B124 page menu: \(page.items.map { "\($0.role):\($0.title)" })")
        for role in [PageContextMenuRole.back, .forward, .reload, .viewSource, .inspect] {
            XCTAssertTrue(roles.contains(role), "missing \(role)")
        }
        XCTAssertFalse(page.target.isLink)
        // Chromium's mnemonic marks are gone ("&Back" -> "Back").
        XCTAssertEqual(page.item(.back)?.title, "Back")
        XCTAssertEqual(page.item(.inspect)?.title, "Inspect")
        XCTAssertEqual(page.items(.extension).count, 1)
        func extensionItems(_ items: [PageContextMenuItem]) -> [PageContextMenuItem] {
            items.flatMap { $0.role == .extension ? [$0] + extensionItems($0.children) : extensionItems($0.children) }
        }
        let item = try XCTUnwrap(extensionItems(page.items).first { $0.title == "B116 item" }, "extension item missing")
        XCTAssertEqual(item.extensionID, extensionID)
        page.session.perform(item.id)
        page.session.close()

        var clicked = ""
        for _ in 0..<100 {
            clicked = try await tab.evaluateJavaScript(SampleLeftoversExtension.clickedScript)
            if !clicked.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(clicked.hasPrefix("b116-"), "onClicked did not fire: \(clicked)")

        let actionItems = await engine.extensions.actionMenuItems(extensionID: extensionID, tabID: tab.id)
        XCTAssertEqual(actionItems.map(\.title), ["B116 item"])

        // A link (focused: the keyboard menu is for the focused element): Chromium's link items
        // and the link's URL.
        let linkPage = try XCTUnwrap(URL(string: "data:text/html,<title>Links</title><a href='https://example.com/next' "
            + "style='display:block;width:300px;height:120px'>next page</a>"))
        try await tab.load(linkPage)
        try await waitForState(tab) { $0.title == "Links" && !$0.loadState.isLoading }
        _ = try await tab.evaluateJavaScript("document.querySelector('a').focus(); 1")
        let linkEvents = tab.events()
        let linkMenu = try await withTimeout(seconds: 20) { () -> PageContextMenu? in
            await chromiumTab.requestContextMenu(x: 20, y: 20)
            for await event in linkEvents { if case .contextMenuRequested(let menu) = event { return menu } }
            return nil
        }
        let link = try XCTUnwrap(linkMenu, "no link menu")
        XCTAssertEqual(link.target.linkURL, URL(string: "https://example.com/next"))
        for role in [PageContextMenuRole.openLinkInNewTab, .openLinkInNewWindow, .saveLinkAs, .copyLinkAddress, .inspect] {
            XCTAssertNotNil(link.item(role), "link menu misses \(role)")
        }
        link.session.close()
    }
}

/// The sample extension of plan B116: a popup (so `action.openPopup()` has one to open), a side
/// panel path, the `contextMenus` permission, and a page that runs the probe.
enum SampleLeftoversExtension {
    static let manifest = """
    {
      "manifest_version": 3,
      "name": "B116 leftovers probe",
      "version": "1.0",
      "permissions": ["contextMenus", "sidePanel", "storage"],
      "background": { "service_worker": "worker.js" },
      "action": { "default_popup": "popup.html", "default_title": "B116" },
      "side_panel": { "default_path": "panel.html" }
    }
    """

    static let files: [String: String] = [
        "manifest.json": manifest,
        "probe.html": "<!doctype html><title>B116 probe</title><p>probe</p>",
        "popup.html": "<!doctype html><title>B116 popup</title><p>popup</p>",
        "panel.html": "<!doctype html><title>B116 panel</title><p>panel</p>",
        // B124: records the menu item the user chose.
        "worker.js": """
        chrome.contextMenus.onClicked.addListener((info) => {
          chrome.storage.session.set({ clicked: String(info.menuItemId) });
        });
        """,
    ]

    /// The id of the item `contextMenus.onClicked` reported, or "" (B124).
    static let clickedScript = """
    chrome.storage.session.get('clicked').then((value) => value.clicked || '')
    """

    /// Runs each API call with a 3 s limit and reports "ok", "ok:<json>", "error:<message>" or
    /// "timeout" per call, as a JSON object.
    static let probeScript = """
    (async () => {
      const results = {};
      const limit = (promise) => Promise.race([
        promise, new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 3000))]);
      const run = async (key, call, plain) => {
        try {
          const value = await limit(call());
          results[key] = plain ? 'ok' : 'ok:' + JSON.stringify(value ?? null);
        } catch (error) {
          results[key] = error.message === 'timeout' ? 'timeout' : 'error:' + error.message;
        }
      };
      await run('contextMenusCreate', () => new Promise((resolve, reject) => {
        chrome.contextMenus.create(
          { id: 'b116-' + Date.now(), title: 'B116 item', contexts: ['page', 'action'] },
          () => chrome.runtime.lastError ? reject(new Error(chrome.runtime.lastError.message)) : resolve(true));
      }), true);
      await run('windowsGetCurrent', () => chrome.windows.getCurrent());
      await run('windowsGetLastFocused', () => chrome.windows.getLastFocused());
      await run('windowsGetAll', () => chrome.windows.getAll());
      await run('actionOpenPopup', () => chrome.action.openPopup());
      const self = await chrome.tabs.getCurrent();
      await run('sidePanelOpen', () => chrome.sidePanel.open({ tabId: self ? self.id : -1 }));
      return JSON.stringify(results);
    })()
    """

    /// Writes the extension into a new folder below `directory` and returns that folder.
    static func write(into directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("b116-sample-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }
}
