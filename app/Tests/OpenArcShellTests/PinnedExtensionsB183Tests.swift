import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B183 (issue #2): pinning extensions. Spec: docs/arc-spec/06-flows.md §31 (observed): the
/// pin badge on an extension in the Site Control Center pins and unpins it; a pinned extension
/// shows in the URL box left of copy link, or in the toolbar left of the site controls; its
/// right-click menu has Remove … · Unpin ‖ Manage Extension. Pins are kept per profile on this
/// device (inferred).
@MainActor
final class PinnedExtensionsB183Tests: XCTestCase {
    private var engine: FakeEngine!
    private var preferences: AppPreferences!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        preferences = .inMemory()
        model = makeModel()
        model.siteControls.pointerLeaveGrace = 0
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
        preferences = nil
    }

    private func makeModel() -> ShellModel {
        ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    private var profileID: UUID { model.sidebar.currentProfileID! }

    private func openPage(_ address: String) async throws {
        _ = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            await model.siteControls.settle()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func install(_ id: String, name: String, hasPopup: Bool = false) {
        engine.fakeExtensionService.simulateInstalled(EngineExtensionInfo(id: id, name: name, hasPopup: hasPopup), profileID: profileID)
    }

    /// `06 §31` observed: clicking the badge pins (the bubble stays open), clicking again unpins.
    func testTogglePinFromSiteControls() async throws {
        try await openPage("https://site.example")
        install("ublock", name: "uBlock")
        let sc = model.siteControls
        sc.present()
        try await waitUntil { sc.settings.extensions.count == 1 }

        XCTAssertFalse(sc.isPinned("ublock"))
        sc.togglePin("ublock")
        XCTAssertTrue(sc.isPinned("ublock"))
        XCTAssertTrue(sc.isPresented, "pinning leaves the bubble open")
        try await waitUntil { sc.pinnedActions.map(\.id) == ["ublock"] }
        XCTAssertEqual(preferences.pinnedExtensionIDs(for: profileID), ["ublock"])

        sc.togglePin("ublock")
        XCTAssertFalse(sc.isPinned("ublock"))
        try await waitUntil { sc.pinnedActions.isEmpty }
        XCTAssertEqual(preferences.pinnedExtensionIDs(for: profileID), [])
    }

    /// `06 §31` observed position in the toolbar: pinned extensions left of the site controls, in
    /// pin order (order inferred).
    func testToolbarShowsPinnedLeftOfSiteControls() async throws {
        try await openPage("https://site.example")
        install("a", name: "A")
        install("b", name: "B")
        let sc = model.siteControls
        sc.togglePin("b")
        sc.togglePin("a")
        try await waitUntil { sc.pinnedActions.count == 2 }
        if !model.isWebToolbarShown { model.toggleWebToolbar() }
        let items = model.webToolbarItems(role: .page)
        XCTAssertEqual(items.trailing, [.pinnedExtension("b"), .pinnedExtension("a"), .siteControls, .splitMenu])

        // Each pinned button sits on the trailing grid, 36 pt apart. [06 §17.2] observed pitch.
        let layout = WebToolbarLayout(barFrame: CGRect(x: 0, y: 0, width: 800, height: 32), items: items,
                                      domainTextWidth: 80, showsInsecureLock: false)
        let site = try XCTUnwrap(layout.frame(of: .siteControls))
        let a = try XCTUnwrap(layout.frame(of: .pinnedExtension("a")))
        let b = try XCTUnwrap(layout.frame(of: .pinnedExtension("b")))
        XCTAssertLessThan(a.maxX, site.minX)
        XCTAssertLessThan(b.maxX, a.minX)
        XCTAssertEqual(a.minX - b.minX, 36, accuracy: 0.001)
    }

    /// Pins are read from this device's preferences for the current profile only (inferred:
    /// kept per profile, like the extensions themselves).
    func testPinsArePerProfile() async throws {
        try await openPage("https://site.example")
        install("ublock", name: "uBlock")
        let sc = model.siteControls
        preferences.setPinnedExtensionIDs(["ublock"], for: UUID())
        sc.refreshPinned()
        await sc.settle()
        XCTAssertFalse(sc.isPinned("ublock"))
        XCTAssertTrue(sc.pinnedActions.isEmpty)

        preferences.setPinnedExtensionIDs(["ublock"], for: profileID)
        sc.refreshPinned()
        XCTAssertTrue(sc.isPinned("ublock"))
        try await waitUntil { sc.pinnedActions.map(\.id) == ["ublock"] }
    }

    /// `06 §31` observed: a pinned icon's menu offers Remove … · Unpin ‖ Manage Extension;
    /// Unpin removes the icon.
    func testPinnedMenuUnpin() async throws {
        try await openPage("https://site.example")
        install("ublock", name: "uBlock")
        let sc = model.siteControls
        sc.togglePin("ublock")
        try await waitUntil { sc.pinnedActions.count == 1 }
        XCTAssertEqual(sc.pinnedExtensionMenuItems(for: "ublock"), [.remove, .unpin, .manage])
        XCTAssertEqual(SiteExtensionMenuItem.unpin.title(extensionName: "uBlock"), "Unpin")
        XCTAssertTrue(sc.isEnabled(.unpin, extensionID: "ublock"))
        sc.perform(.unpin, extensionID: "ublock")
        try await waitUntil { sc.pinnedActions.isEmpty }
        XCTAssertFalse(sc.isPinned("ublock"))
    }

    /// Removing a pinned extension also drops its pin.
    func testRemovingPinnedExtensionUnpins() async throws {
        try await openPage("https://site.example")
        install("ublock", name: "uBlock")
        let sc = model.siteControls
        sc.confirmExtensionRemoval = { _ in true }
        sc.togglePin("ublock")
        try await waitUntil { sc.pinnedActions.count == 1 }
        sc.perform(.remove, extensionID: "ublock")
        try await waitUntil { sc.pinnedActions.isEmpty }
        XCTAssertEqual(preferences.pinnedExtensionIDs(for: profileID), [])
    }

    /// `06 §31` observed: clicking a pinned icon opens the extension's popup, from that icon.
    func testPinnedIconOpensPopup() async throws {
        try await openPage("https://site.example")
        install("pop", name: "Pop", hasPopup: true)
        let sc = model.siteControls
        sc.togglePin("pop")
        try await waitUntil { sc.pinnedActions.count == 1 }
        sc.runPinnedExtension("pop")
        try await waitUntil { sc.extensionPopup != nil }
        XCTAssertEqual(sc.extensionPopup?.extensionID, "pop")
        XCTAssertEqual(sc.extensionPopup?.isFromPinnedIcon, true)
        XCTAssertFalse(sc.isPresented)
    }

    /// A pinned extension the profile no longer has shows no icon; its pin stays harmlessly.
    func testPinWithoutInstalledExtensionShowsNothing() async throws {
        try await openPage("https://site.example")
        preferences.setPinnedExtensionIDs(["gone"], for: profileID)
        let sc = model.siteControls
        sc.refreshPinned()
        await sc.settle()
        XCTAssertEqual(sc.pinnedExtensionIDs, ["gone"])
        XCTAssertTrue(sc.pinnedActions.isEmpty)
    }
}
