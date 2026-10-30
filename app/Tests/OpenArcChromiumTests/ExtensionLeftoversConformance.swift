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

        await engine.closeTab(tab.id)
        await engine.extensions.uninstall(extensionID, profileID: profileID)
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
      "permissions": ["contextMenus", "sidePanel"],
      "action": { "default_popup": "popup.html", "default_title": "B116" },
      "side_panel": { "default_path": "panel.html" }
    }
    """

    static let files: [String: String] = [
        "manifest.json": manifest,
        "probe.html": "<!doctype html><title>B116 probe</title><p>probe</p>",
        "popup.html": "<!doctype html><title>B116 popup</title><p>popup</p>",
        "panel.html": "<!doctype html><title>B116 panel</title><p>panel</p>",
    ]

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
