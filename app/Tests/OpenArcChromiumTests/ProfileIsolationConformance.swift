import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// C11: profile isolation in the real engine, run from `testChromiumEngineConformance` (Chromium
/// starts once per process). Two on-disk profiles and an incognito context each see only their own
/// cookies, localStorage, IndexedDB and service workers (`ProfileIsolationSite`) and their own zoom
/// levels (per-profile content settings); the incognito context leaves nothing on disk and starts
/// empty again after its last tab closed; clearing browsing data empties a profile; deleting a
/// profile removes its directory. [03 §Profiles] observed: "Profiles help keep your data separate
/// across Spaces — like history, logins, cookies, and extensions." [06 §16.3] observed: deleting a
/// Profile "will permanently remove any cookies, history, preferences, and logins".
extension ChromiumEngineConformanceTests {
    @MainActor
    func checkProfileIsolation(_ engine: ChromiumEngine, dataDirectory: URL, defaultProfile: UUID) async throws {
        let server = try ProfileIsolationServer()
        try await server.start()
        defer { server.stop() }
        let work = defaultProfile
        let personal = UUID()

        // Work writes; Personal sees nothing, then writes its own values.
        let workTab = try await engine.makeTab(TabConfiguration(profileID: work))
        try await expectTitle(workTab, server.url("mode=write&tag=alpha"), "written:alpha")
        let personalTab = try await engine.makeTab(TabConfiguration(profileID: personal))
        try await expectTitle(personalTab, server.url("mode=read"), ProfileIsolationSite.sawNothing)
        try await expectTitle(personalTab, server.url("mode=write&tag=beta"), "written:beta")
        try await expectTitle(personalTab, server.url("mode=read"), ProfileIsolationSite.sawEverything("beta"))
        // A second Work tab still sees Work's values only.
        let workTab2 = try await engine.makeTab(TabConfiguration(profileID: work))
        try await expectTitle(workTab2, server.url("mode=read"), ProfileIsolationSite.sawEverything("alpha"))

        // Zoom levels are per profile (Chromium's per-context host zoom map).
        try await workTab2.setZoom(1.5)
        try await waitForState(workTab2) { abs($0.zoomFactor - 1.5) < 0.01 }
        try await expectTitle(personalTab, server.url("mode=read"), ProfileIsolationSite.sawEverything("beta"))
        let personalZoom = await personalTab.currentState().zoomFactor
        XCTAssertEqual(personalZoom, 1, accuracy: 0.01, "Personal keeps its own zoom for the site")
        await workTab2.resetZoom()

        // Incognito of Work: empty, writes stay in it, nothing new on disk.
        let entriesBefore = try directoryEntries(dataDirectory)
        let secret = try await engine.makeTab(TabConfiguration(profileID: work, isOffTheRecord: true))
        try await expectTitle(secret, server.url("mode=read"), ProfileIsolationSite.sawNothing)
        try await expectTitle(secret, server.url("mode=write&tag=gamma"), "written:gamma")
        try await expectTitle(secret, server.url("mode=read"), ProfileIsolationSite.sawEverything("gamma"))
        try await expectTitle(workTab2, server.url("mode=read"), ProfileIsolationSite.sawEverything("alpha"))
        XCTAssertEqual(try directoryEntries(dataDirectory), entriesBefore, "incognito adds nothing to the user data dir")
        // Closing the last incognito tab destroys the context: the next one starts empty.
        await engine.closeTab(secret.id)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let secret2 = try await engine.makeTab(TabConfiguration(profileID: work, isOffTheRecord: true))
        try await expectTitle(secret2, server.url("mode=read"), ProfileIsolationSite.sawNothing)
        await engine.closeTab(secret2.id)

        // Clearing cookies + site storage + cache + history empties Personal, not Work.
        await engine.clearBrowsingData(personal, types: .all, since: nil)
        try await expectTitle(personalTab, server.url("mode=read"), ProfileIsolationSite.sawNothing)
        try await expectTitle(workTab2, server.url("mode=read"), ProfileIsolationSite.sawEverything("alpha"))

        // Deleting Personal needs its tabs closed, then removes its directory.
        let personalDirectory = dataDirectory.appendingPathComponent(personal.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalDirectory.path))
        do {
            try await engine.deleteProfileData(personal)
            XCTFail("deleting a profile with open tabs must fail")
        } catch {
            XCTAssertEqual(error as? EngineError, .invalidArgument)
        }
        await engine.closeTab(personalTab.id)
        try await engine.deleteProfileData(personal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: personalDirectory.path), "the profile's directory is gone")
        // Work is untouched.
        try await expectTitle(workTab2, server.url("mode=read"), ProfileIsolationSite.sawEverything("alpha"))
        await engine.closeTab(workTab.id)
        await engine.closeTab(workTab2.id)
    }

    /// Loads `url` and waits until the page reports `expected` in its title.
    @MainActor
    private func expectTitle(_ tab: any BrowserTab, _ base: URL, _ expected: String, line: UInt = #line) async throws {
        // A unique URL per load, so the previous page's title never counts.
        let url = URL(string: base.absoluteString + "&n=" + UUID().uuidString)!
        try await tab.load(url)
        let deadline = Date().addingTimeInterval(20)
        var title = ""
        while Date() < deadline {
            title = await tab.currentState().title
            if title.hasPrefix("read:") || title.hasPrefix("written:") || title.hasPrefix("error:") {
                let committed = await tab.currentState().committedURL
                if committed == url { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(title, expected, "\(url)", line: line)
    }

    private func directoryEntries(_ url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }
}
