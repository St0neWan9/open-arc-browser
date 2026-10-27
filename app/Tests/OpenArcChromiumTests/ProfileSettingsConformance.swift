import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B83: Settings ▸ Profiles in the real engine, run from `testChromiumEngineConformance`.
/// [03 §Profiles] observed: "Download location" is a per-Profile setting (default Downloads), and
/// the "Your Data and Settings" rows lead to the profile's data pages (inferred: the engine's own
/// settings pages, opened in a tab of that profile).
extension ChromiumEngineConformanceTests {
    @MainActor
    func checkProfileSettings(_ engine: ChromiumEngine, dataDirectory: URL) async throws {
        let first = UUID()
        let second = UUID()
        let folder = dataDirectory.appendingPathComponent("b83-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The download folder is the profile's own, and reads back.
        await engine.downloads.setDefaultDirectory(folder, profileID: first)
        let read = await engine.downloads.defaultDirectory(profileID: first)
        XCTAssertEqual(read?.standardizedFileURL.path, folder.standardizedFileURL.path)
        let other = await engine.downloads.defaultDirectory(profileID: second)
        XCTAssertNotEqual(other?.standardizedFileURL.path, folder.standardizedFileURL.path, "another profile keeps its folder")

        // The pages the rows open load in a tab of the profile (WebUI, no network).
        let tab = try await engine.makeTab(TabConfiguration(profileID: first))
        for page in ["chrome://settings/privacy", "chrome://password-manager/passwords", "chrome://settings/searchEngines"] {
            let url = try XCTUnwrap(URL(string: page))
            try await tab.load(url)
            try await waitForState(tab) { $0.committedURL?.host == url.host && !$0.loadState.isLoading && !$0.title.isEmpty }
        }
        await engine.closeTab(tab.id)

        // Clearing the new kinds (passwords, autofill, site settings) completes.
        await engine.clearBrowsingData(first, types: [.passwords, .autofill, .siteSettings], since: nil)
    }
}
