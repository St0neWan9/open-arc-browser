import XCTest
import OpenArcEngine

final class FakeEngineTests: XCTestCase {
    private let profile = UUID()

    /// Collects the first `count` events of a stream, then stops (so tests never hang).
    private func take<S: AsyncSequence>(_ count: Int, from stream: S) async rethrows -> [S.Element] {
        var result: [S.Element] = []
        guard count > 0 else { return result }
        for try await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    func testMakeTabWithInitialURLLoadsIt() async throws {
        let engine = FakeEngine()
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: url))
        let state = await tab.currentState()
        XCTAssertEqual(state.url, url)
        XCTAssertEqual(state.title, "example.com")
        XCTAssertEqual(state.loadState, .idle)
        XCTAssertEqual(state.favicon?.url, URL(string: "https://example.com/favicon.ico"))
        XCTAssertEqual(tab.profileID, profile)
        XCTAssertEqual(engine.tabIDs, [tab.id])
    }

    /// B14: an incognito window's tabs are created off the record; regular tabs are not.
    /// [01 §File] observed "New Incognito Window"; the off-the-record flag is inferred.
    func testOffTheRecordFlagIsKeptPerTab() async throws {
        let engine = FakeEngine()
        let regular = try await engine.makeTab(TabConfiguration(profileID: profile))
        let incognito = try await engine.makeTab(TabConfiguration(profileID: profile, isOffTheRecord: true))
        XCTAssertFalse(try XCTUnwrap(regular as? FakeTab).isOffTheRecord)
        XCTAssertTrue(try XCTUnwrap(incognito as? FakeTab).isOffTheRecord)
        XCTAssertEqual(engine.offTheRecordTabIDs, [incognito.id])
        await engine.closeTab(incognito.id)
        XCTAssertTrue(engine.offTheRecordTabIDs.isEmpty)
        XCTAssertEqual(engine.tabIDs, [regular.id])
    }

    func testEventStreamStartsWithSnapshotThenNavigationSequence() async throws {
        let engine = FakeEngine(titleProvider: { _ in "Title" })
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let stream = tab.events()
        let url = try XCTUnwrap(URL(string: "https://a.example"))
        try await tab.load(url)

        let events = await take(9, from: stream)
        XCTAssertEqual(events, [
            .snapshot(BrowserTabState()),
            .loadStateChanged(LoadState(isLoading: true, progress: 0)),
            .urlChanged(url),
            .committedURLChanged(url),
            .securityChanged(.secure),
            .titleChanged("Title"),
            .faviconChanged(Favicon(url: URL(string: "https://a.example/favicon.ico"))),
            .navigationStateChanged(.none),
            .loadStateChanged(.idle),
        ])
    }

    func testBackForwardHistory() async throws {
        let engine = FakeEngine()
        let a = try XCTUnwrap(URL(string: "https://a.example"))
        let b = try XCTUnwrap(URL(string: "https://b.example"))
        let c = try XCTUnwrap(URL(string: "https://c.example"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: a))
        try await tab.load(b)
        var state = await tab.currentState()
        XCTAssertEqual(state.navigation, NavigationState(canGoBack: true, canGoForward: false))

        try await tab.goBack()
        state = await tab.currentState()
        XCTAssertEqual(state.url, a)
        XCTAssertEqual(state.navigation, NavigationState(canGoBack: false, canGoForward: true))

        try await tab.goForward()
        state = await tab.currentState()
        XCTAssertEqual(state.url, b)

        // A new load after going back truncates forward history.
        try await tab.goBack()
        try await tab.load(c)
        state = await tab.currentState()
        XCTAssertEqual(state.navigation, NavigationState(canGoBack: true, canGoForward: false))

        // Going back at the start is a no-op.
        try await tab.goBack()
        try await tab.goBack()
        state = await tab.currentState()
        XCTAssertEqual(state.url, a)
    }

    func testTwoSubscribersBothReceiveEvents() async throws {
        let engine = FakeEngine(titleProvider: { _ in "T" })
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let first = tab.events()
        let second = tab.events()
        try await tab.load(try XCTUnwrap(URL(string: "https://x.example")))
        let e1 = await take(6, from: first)
        let e2 = await take(6, from: second)
        XCTAssertEqual(e1, e2)
        XCTAssertEqual(e1.last, .titleChanged("T"))
    }

    func testLateSubscriberGetsCurrentSnapshot() async throws {
        let engine = FakeEngine()
        let url = try XCTUnwrap(URL(string: "https://late.example"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: url))
        let events = await take(1, from: tab.events())
        guard case .snapshot(let state)? = events.first else { return XCTFail("expected snapshot") }
        XCTAssertEqual(state.url, url)
    }

    func testCloseEndsTabStreamAndEmitsEngineEvent() async throws {
        let engine = FakeEngine()
        let engineEvents = engine.events()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let tabEvents = tab.events()
        await engine.closeTab(tab.id)

        var received: [TabEvent] = []
        for await event in tabEvents { received.append(event) }   // finishes on close
        XCTAssertEqual(received.last, .closed)

        let engineReceived = await take(1, from: engineEvents)
        XCTAssertEqual(engineReceived, [.tabClosed(tab.id)])
        let lookup = await engine.tab(for: tab.id)
        XCTAssertNil(lookup)

        do {
            try await tab.load(try XCTUnwrap(URL(string: "https://x.example")))
            XCTFail("expected tabClosed")
        } catch {
            XCTAssertEqual(error as? EngineError, .tabClosed(tab.id))
        }
    }

    func testRequestedIDAndDuplicateRejection() async throws {
        let engine = FakeEngine()
        let id = EngineTabID(UUID())
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, requestedID: id))
        XCTAssertEqual(tab.id, id)
        do {
            _ = try await engine.makeTab(TabConfiguration(profileID: profile, requestedID: id))
            XCTFail("expected duplicate error")
        } catch {
            XCTAssertEqual(error as? EngineError, .duplicateTabID(id))
        }
    }

    func testNewTabRequestIsBroadcast() async throws {
        let engine = FakeEngine()
        let stream = engine.events()
        let request = NewTabRequest(opener: nil, url: try XCTUnwrap(URL(string: "https://popup.example")), disposition: .popup, hasUserGesture: true)
        engine.simulateNewTabRequest(request)
        let events = await take(1, from: stream)
        XCTAssertEqual(events, [.newTabRequested(request)])
    }

    func testSnapshotReturnsDecodablePNG() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let snapshot = try await tab.snapshot(maxPixelSize: 256)
        XCTAssertEqual(snapshot.pixelWidth, 1)
        XCTAssertEqual(Array(snapshot.pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testCrashIsReported() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let stream = tab.events()
        (tab as? FakeTab)?.simulateCrash()
        let events = await take(2, from: stream)
        XCTAssertEqual(events.last, .renderProcessGone)
        let state = await tab.currentState()
        XCTAssertTrue(state.isCrashed)
    }

    func testBroadcasterRemovesTerminatedSubscribers() async {
        let broadcaster = AsyncBroadcaster<Int>()
        do {
            let stream = broadcaster.subscribe(initial: [1])
            XCTAssertEqual(broadcaster.subscriberCount, 1)
            let first = await take(1, from: stream)
            XCTAssertEqual(first, [1])
        }
        // The stream (and its iterator) is gone; give onTermination a moment.
        for _ in 0..<100 where broadcaster.subscriberCount > 0 {
            await Task.yield()
        }
        XCTAssertEqual(broadcaster.subscriberCount, 0)
        broadcaster.finish()
        let afterFinish = await take(5, from: broadcaster.subscribe(initial: [7]))
        XCTAssertEqual(afterFinish, [7])
    }
}

/// Surface hosting: a test host records what the surface shows.
@MainActor
final class SurfaceTests: XCTestCase {
    private final class RecordingHost: SurfaceHost {
        var shown: [SurfacePlaceholder] = []
        var cleared = 0
        func show(_ content: SurfaceContent) {
            if case .placeholder(let p) = content { shown.append(p) }
        }
        func clear() { cleared += 1 }
    }

    func testAttachShowsPlaceholderAndMovesBetweenHosts() async throws {
        let engine = FakeEngine(titleProvider: { _ in "Page" })
        let url = try XCTUnwrap(URL(string: "https://s.example"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID(), initialURL: url))
        let hostA = RecordingHost()
        let hostB = RecordingHost()

        tab.surface.attach(to: hostA)
        XCTAssertEqual(hostA.shown.last, SurfacePlaceholder(title: "Page", url: url))

        // A surface lives in at most one host: attaching elsewhere clears the old host.
        tab.surface.attach(to: hostB)
        XCTAssertEqual(hostA.cleared, 1)
        XCTAssertEqual(hostB.shown.count, 1)

        tab.surface.detach()
        XCTAssertEqual(hostB.cleared, 1)
        XCTAssertEqual((tab.surface as? FakeSurface)?.isAttached, false)
    }
}

/// B21: the color scheme pages see. [04 §dark mode] observed `prefers-color-scheme: dark` in dark Spaces.
final class ColorSchemeEngineTests: XCTestCase {
    private let profile = UUID()

    func testPreferredColorSchemeFromConfigurationAndChanges() async throws {
        let engine = FakeEngine()
        let lightTab = try await engine.makeTab(TabConfiguration(profileID: profile))
        let light = try XCTUnwrap(lightTab as? FakeTab)
        XCTAssertEqual(light.preferredColorScheme, .light, "light by default")
        let darkTab = try await engine.makeTab(TabConfiguration(profileID: profile, preferredColorScheme: .dark))
        let dark = try XCTUnwrap(darkTab as? FakeTab)
        XCTAssertEqual(dark.preferredColorScheme, .dark)

        await light.setPreferredColorScheme(.dark)
        await light.setPreferredColorScheme(.dark)
        await light.setPreferredColorScheme(.light)
        XCTAssertEqual(light.colorSchemeChanges, [.dark, .light], "repeats are ignored")
        XCTAssertEqual(light.preferredColorScheme, .light)
        XCTAssertTrue(light.commands.isEmpty, "kept out of the command log")

        await engine.closeTab(light.id)
        await light.setPreferredColorScheme(.dark)
        XCTAssertEqual(light.colorSchemeChanges, [.dark, .light], "a closed tab ignores it")
    }

    /// A script-opened tab starts with its opener's scheme (inferred).
    func testAdoptedTabInheritsTheOpenersColorScheme() async throws {
        let engine = FakeEngine()
        let opener = try await engine.makeTab(TabConfiguration(profileID: profile, preferredColorScheme: .dark))
        let token = try XCTUnwrap(engine.simulateWindowOpen(from: opener.id, url: try XCTUnwrap(URL(string: "https://example.com/popup"))))
        let adoptedTab = try await engine.adoptTab(token, requestedID: nil)
        let adopted = try XCTUnwrap(adoptedTab as? FakeTab)
        XCTAssertEqual(adopted.preferredColorScheme, .dark)
    }

    /// The placeholder surface reports the scheme, so the shell draws a dark placeholder page.
    @MainActor
    func testPlaceholderCarriesTheColorScheme() async throws {
        final class Host: SurfaceHost {
            var shown: [SurfaceContent] = []
            func show(_ content: SurfaceContent) { shown.append(content) }
            func clear() {}
        }
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://example.com")))
        let host = Host()
        tab.surface.attach(to: host)
        await tab.setPreferredColorScheme(.dark)
        guard case .placeholder(let last)? = host.shown.last else { return XCTFail("no placeholder") }
        XCTAssertEqual(last.colorScheme, .dark)
    }
}
