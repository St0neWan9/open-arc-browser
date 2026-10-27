import Foundation
import AppKit
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B70: AppleScript support. Spec: docs/arc-spec/06-flows.md §29 — the dictionary (§29.1–
/// §29.3, observed: one suite, 4 classes, 10 commands, properties, read-only flags, codes) and
/// the JavaScript gate (§29.4: View ▸ Developer ▸ Allow JavaScript from Apple Events, default off
/// inferred). Runtime behavior is inferred (§29.3: never run against Arc).
@MainActor
final class ScriptingTests: XCTestCase {
    private var engine: FakeEngine!
    private var preferences: AppPreferences!
    private var controller: WorkspaceController!
    private var host: ScriptingHost!
    private let f = SidebarFixture()

    override func setUp() async throws {
        engine = FakeEngine()
        preferences = .inMemory()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences)
        let fixed = f.now.addingTimeInterval(10)
        let ids = SidebarIDSource()
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, makeID: { ids.make() },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        var next = 5_000
        host = ScriptingHost(makeID: { next += 1; return SidebarFixture.id(next) })
    }

    override func tearDown() async throws {
        controller.stop()
    }

    private func window(space: UUID? = nil, tab: UUID? = nil) -> (ShellModel, UUID) {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space ?? f.home, selectedTabID: tab))
        addTeardownBlock { @MainActor in model.stop() }
        host.register(model, window: nil)
        return (model, host.entry(for: model)!.id)
    }

    // MARK: Dictionary ([06 §29.1–§29.3] observed)

    private func dictionary() throws -> XMLDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bundle/OpenArc.sdef")
        return try XMLDocument(contentsOf: url, options: [])
    }

    private func nodes(_ doc: XMLDocument, _ xpath: String) throws -> [XMLElement] {
        try doc.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    /// One suite, "Standard Suite" (core); 4 classes and 10 commands with the observed codes.
    func testDictionaryClassesAndCommandsMatchSpec29() throws {
        let doc = try dictionary()
        let suites = try nodes(doc, "/dictionary/suite")
        XCTAssertEqual(suites.map { $0.attribute(forName: "name")?.stringValue }, ["Standard Suite"])
        XCTAssertEqual(suites.first?.attribute(forName: "code")?.stringValue, "core")

        let classes = try nodes(doc, "//class").map { ($0.attribute(forName: "name")!.stringValue!, $0.attribute(forName: "code")!.stringValue!) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: classes), [
            "application": "capp", "window": "WiND", "tab": "tAbB", "space": "sPaC",
        ])
        let commands = try nodes(doc, "//command").map { ($0.attribute(forName: "name")!.stringValue!, $0.attribute(forName: "code")!.stringValue!) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: commands), [
            "make": "corecrel", "count": "corecnte", "close": "coreclos", "select": "CrSelect",
            "go back": "CrSuBack", "go forward": "CrSuFwd ", "reload": "CrSuRlod", "stop": "CrSustop",
            "execute": "CrSuExJa", "focus": "SpaFocus",
        ])
        let execute = try XCTUnwrap(nodes(doc, "//command[@name='execute']/parameter").first)
        XCTAssertEqual(execute.attribute(forName: "name")?.stringValue, "javascript")
        XCTAssertEqual(execute.attribute(forName: "code")?.stringValue, "JvSc")
        XCTAssertEqual(try nodes(doc, "//command[@name='execute']/result").first?.attribute(forName: "type")?.stringValue, "text")
        let make = try nodes(doc, "//command[@name='make']/parameter").map { $0.attribute(forName: "code")!.stringValue! }
        XCTAssertEqual(make, ["kocl", "prdt"], "make has no `at` parameter")
    }

    /// Every property of [06 §29.2] with its code, type and read-only flag.
    func testDictionaryPropertiesMatchSpec29_2() throws {
        let doc = try dictionary()
        // name: (code, type, read-only)
        let expected: [String: [String: (String, String, Bool)]] = [
            "application": ["name": ("pnam", "text", true), "frontmost": ("pisf", "boolean", true), "version": ("vers", "text", true)],
            "window": [
                "id": ("ID  ", "text", true), "name": ("pnam", "text", true), "index": ("pidx", "integer", false),
                "closeable": ("hclb", "boolean", true), "minimizable": ("ismn", "boolean", true),
                "minimized": ("pmnd", "boolean", false), "resizable": ("prsz", "boolean", true),
                "visible": ("pvis", "boolean", false), "zoomable": ("iszm", "boolean", true),
                "zoomed": ("pzum", "boolean", false), "active tab": ("acTa", "tab", true),
                "active space": ("acSp", "space", true), "incognito": ("inco", "boolean", false),
                "mode": ("mode", "text", false),
            ],
            "tab": [
                "id": ("ID  ", "text", true), "title": ("pnam", "text", true), "URL": ("URL ", "text", false),
                "loading": ("ldng", "boolean", true), "location": ("loca", "text", false),
            ],
            "space": ["id": ("ID  ", "text", true), "title": ("pnam", "text", true)],
        ]
        for (className, properties) in expected {
            let found = try nodes(doc, "//class[@name='\(className)']/property")
            XCTAssertEqual(Set(found.map { $0.attribute(forName: "name")!.stringValue! }), Set(properties.keys), className)
            for property in found {
                let name = property.attribute(forName: "name")!.stringValue!
                guard let (code, type, readOnly) = properties[name] else { continue }
                XCTAssertEqual(property.attribute(forName: "code")?.stringValue, code, "\(className).\(name)")
                XCTAssertEqual(property.attribute(forName: "type")?.stringValue, type, "\(className).\(name)")
                XCTAssertEqual(property.attribute(forName: "access")?.stringValue == "r", readOnly, "\(className).\(name)")
            }
        }
        // Elements: application windows + write-only tabs; window tabs (rw) + spaces; space tabs (rw).
        func elements(_ c: String) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try nodes(doc, "//class[@name='\(c)']/element").map {
                ($0.attribute(forName: "type")!.stringValue!, $0.attribute(forName: "access")?.stringValue ?? "rw")
            })
        }
        XCTAssertEqual(try elements("application"), ["window": "rw", "tab": "w"])
        XCTAssertEqual(try elements("window"), ["tab": "rw", "space": "rw"])
        XCTAssertEqual(try elements("space"), ["tab": "rw"])
        func respondsTo(_ c: String) throws -> Set<String> {
            Set(try nodes(doc, "//class[@name='\(c)']/responds-to").map { $0.attribute(forName: "command")!.stringValue! })
        }
        XCTAssertEqual(try respondsTo("tab"), ["select", "go back", "go forward", "reload", "stop", "execute", "close"])
        XCTAssertEqual(try respondsTo("window"), ["close"])
        XCTAssertEqual(try respondsTo("space"), ["focus"])
        XCTAssertEqual(try respondsTo("application"), ["quit"])
    }

    /// Every Cocoa class the dictionary names is one of ours and exists at runtime, with the
    /// handler selectors the dictionary binds.
    func testDictionaryCocoaBindingsExist() throws {
        let doc = try dictionary()
        for name in try nodes(doc, "//cocoa[@class]").map({ $0.attribute(forName: "class")!.stringValue! }) {
            XCTAssertNotNil(NSClassFromString(name), name)
        }
        let bindings: [(String, String)] = try nodes(doc, "//class").flatMap { cls -> [(String, String)] in
            let cocoa = try cls.nodes(forXPath: "cocoa").first as? XMLElement
            let className = cocoa?.attribute(forName: "class")?.stringValue ?? ""
            return try cls.nodes(forXPath: "responds-to/cocoa").compactMap { ($0 as? XMLElement)?.attribute(forName: "method")?.stringValue }
                .map { (className, $0) }
        }
        for (className, method) in bindings {
            let cls: AnyClass = try XCTUnwrap(NSClassFromString(className), className)
            XCTAssertTrue(cls.instancesRespond(to: NSSelectorFromString(method)), "\(className) \(method)")
        }
        // Property and element keys answer KVC on our classes.
        let keyed: [(String, AnyClass)] = [("window", ScriptableWindow.self), ("tab", ScriptableTab.self), ("space", ScriptableSpace.self), ("application", NSApplication.self)]
        for (className, cls): (String, AnyClass) in keyed {
            for key in try nodes(doc, "//class[@name='\(className)']/*/cocoa[@key]").map({ $0.attribute(forName: "key")!.stringValue! }) {
                XCTAssertTrue(cls.instancesRespond(to: NSSelectorFromString(key)), "\(className) key \(key)")
            }
        }
    }

    func testFourCharCodes() {
        XCTAssertEqual(ScriptingCodes.tab, 0x7441_6242) // 'tAbB'
        XCTAssertEqual(ScriptingCodes.window, 0x5769_4E44) // 'WiND'
        XCTAssertEqual(FourCharCode(fourCharacters: "subj"), 0x7375_626A) // keySubjectAttr
    }

    // MARK: Ids and lookup

    func testWindowIDLookup() throws {
        let (a, aID) = window()
        let (b, bID) = window(space: f.work)
        XCTAssertNotEqual(aID, bID)
        XCTAssertTrue(try host.model(forWindow: aID) === a)
        XCTAssertTrue(try host.model(forWindow: bID) === b)
        host.register(a, window: nil)
        XCTAssertEqual(host.entry(for: a)?.id, aID, "registering again keeps the id")
        XCTAssertThrowsError(try host.model(forWindow: UUID())) { error in
            XCTAssertEqual((error as? ScriptingFailure)?.number, ScriptingFailure.noSuchObjectNumber)
        }
        XCTAssertEqual(ScriptingHost.id(from: aID.uuidString.lowercased()), aID, "ids are case-insensitive")
        XCTAssertNil(ScriptingHost.id(from: "not an id"))
        XCTAssertNil(ScriptingHost.id(from: 42))
    }

    /// A window that went away is gone from the list.
    func testStoppedWindowLeavesTheList() {
        var model: ShellModel? = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        host.register(model!, window: nil)
        XCTAssertEqual(host.windows.count, 1)
        model?.stop()
        model = nil
        XCTAssertTrue(host.windows.isEmpty)
    }

    /// A window's tabs are its Space's, in sidebar order: favorites, pinned (depth first), Today.
    func testTabElementsAndLookup() throws {
        let (_, windowID) = window()
        let expected = [f.fav1, f.fav2, f.deepTab, f.inFolderTab, f.pinnedTab, f.today3, f.today2, f.today1]
        XCTAssertEqual(host.tabIDs(inWindow: windowID), expected)
        let scriptable = ScriptableWindow(windowID: windowID, host: host)
        XCTAssertEqual(scriptable.scriptingTabs.map(\.tabID), expected)
        XCTAssertEqual(scriptable.valueInScriptingTabs(withUniqueID: f.today1.uuidString)?.tabID, f.today1)
        XCTAssertNil(scriptable.valueInScriptingTabs(withUniqueID: f.workTab.uuidString), "a tab of another Space")
        XCTAssertEqual(Set(scriptable.scriptingSpaces.map(\.spaceID)), [f.home, f.work])
        let work = try XCTUnwrap(scriptable.valueInScriptingSpaces(withUniqueID: f.work.uuidString))
        XCTAssertEqual(work.scriptingTitle, "Work")
        XCTAssertEqual(work.scriptingTabs.map(\.tabID), [f.fav1, f.fav2, f.workTab])
        XCTAssertNil(scriptable.valueInScriptingSpaces(withUniqueID: UUID().uuidString))
    }

    func testTabProperties() {
        let (_, windowID) = window()
        let fav = ScriptableTab(tabID: f.fav1, container: .window(windowID), host: host)
        let pinned = ScriptableTab(tabID: f.pinnedTab, container: .window(windowID), host: host)
        let today = ScriptableTab(tabID: f.today1, container: .window(windowID), host: host)
        XCTAssertEqual(fav.scriptingLocation, "topApp")
        XCTAssertEqual(pinned.scriptingLocation, "pinned")
        XCTAssertEqual(today.scriptingLocation, "unpinned")
        XCTAssertEqual(today.scriptingTitle, "today1")
        XCTAssertEqual(today.scriptingURL, "https://today1.example.com")
        XCTAssertEqual(today.scriptingID, f.today1.uuidString)
        XCTAssertFalse(today.scriptingLoading)
        let scriptable = ScriptableWindow(windowID: windowID, host: host)
        XCTAssertEqual(scriptable.scriptingMode, "normal")
        XCTAssertFalse(scriptable.scriptingIncognito)
        XCTAssertNil(scriptable.scriptingActiveTab)
        XCTAssertEqual(scriptable.scriptingActiveSpace?.spaceID, f.home)
        XCTAssertEqual(scriptable.scriptingIndex, 1)
    }

    // MARK: Object specifiers

    /// Registers class descriptions for our three classes (suite-dictionary form, the codes and
    /// keys of OpenArc.sdef). The test host has no dictionary of its own, and the registry reads
    /// an sdef only from the main bundle.
    private func loadDictionary() {
        guard NSScriptClassDescription(for: ScriptableWindow.self) == nil else { return }
        _ = NSApplication.shared
        let suite = "OpenArcTestSuite"
        func toMany(_ type: String, _ code: String) -> [String: Any] { ["Type": "\(suite).\(type)", "AppleEventCode": code] }
        let classes: [String: [String: Any]] = [
            "OAScriptableWindow": ["AppleEventCode": "WiND", "Superclass": "NSCoreSuite.AbstractObject",
                                   "ToManyRelationships": [ScriptingKeys.tabs: toMany("OAScriptableTab", "tAbB"), ScriptingKeys.spaces: toMany("OAScriptableSpace", "sPaC")]],
            "OAScriptableSpace": ["AppleEventCode": "sPaC", "Superclass": "NSCoreSuite.AbstractObject",
                                  "ToManyRelationships": [ScriptingKeys.tabs: toMany("OAScriptableTab", "tAbB")]],
            "OAScriptableTab": ["AppleEventCode": "tAbB", "Superclass": "NSCoreSuite.AbstractObject"],
        ]
        let declaration: [String: Any] = ["Name": suite, "AppleEventCode": "OAts", "Classes": classes]
        NSScriptSuiteRegistry.shared().loadSuite(with: declaration, from: Bundle.main)
    }

    func testObjectSpecifiers() throws {
        loadDictionary()
        let (_, windowID) = window()
        let scriptable = ScriptableWindow(windowID: windowID, host: host)
        let windowSpec = try XCTUnwrap(scriptable.objectSpecifier as? NSUniqueIDSpecifier)
        XCTAssertEqual(windowSpec.key, ScriptingKeys.applicationWindows)
        XCTAssertEqual(windowSpec.uniqueID as? String, windowID.uuidString)
        XCTAssertNil(windowSpec.container, "a window is an element of the application")

        let tab = ScriptableTab(tabID: f.today1, container: .window(windowID), host: host)
        let tabSpec = try XCTUnwrap(tab.objectSpecifier as? NSUniqueIDSpecifier)
        XCTAssertEqual(tabSpec.key, ScriptingKeys.tabs)
        XCTAssertEqual(tabSpec.uniqueID as? String, f.today1.uuidString)
        XCTAssertEqual((tabSpec.container as? NSUniqueIDSpecifier)?.uniqueID as? String, windowID.uuidString)

        let space = ScriptableSpace(spaceID: f.work, windowID: windowID, host: host)
        let spaceSpec = try XCTUnwrap(space.objectSpecifier as? NSUniqueIDSpecifier)
        XCTAssertEqual(spaceSpec.key, ScriptingKeys.spaces)
        XCTAssertEqual(spaceSpec.uniqueID as? String, f.work.uuidString)

        let spaceTab = ScriptableTab(tabID: f.workTab, container: .space(f.work, window: windowID), host: host)
        let spaceTabSpec = try XCTUnwrap(spaceTab.objectSpecifier as? NSUniqueIDSpecifier)
        let parent = try XCTUnwrap(spaceTabSpec.container as? NSUniqueIDSpecifier)
        XCTAssertEqual(parent.key, ScriptingKeys.spaces)
        XCTAssertEqual(parent.uniqueID as? String, f.work.uuidString)
        // The specifier encodes to an Apple event descriptor (what a script gets back).
        XCTAssertNotNil(spaceTabSpec.descriptor)
        // And evaluates back to the same object through the KVC accessors.
        let resolved = spaceSpec.objectsByEvaluating(withContainers: scriptable) as? ScriptableSpace
        XCTAssertEqual(resolved, space)
    }

    // MARK: Commands

    /// `make new tab` in a window: top of Today, selected; the URL is stored on the tab.
    func testMakeTabInWindow() async throws {
        let (model, windowID) = window()
        let id = try host.makeTab(inWindow: windowID, ScriptTabProperties(url: "https://example.com/a", location: nil))
        XCTAssertEqual(model.workspace.today(spaceID: f.home).first?.id, id)
        XCTAssertEqual(model.selectedTabID, id)
        XCTAssertEqual(model.workspace.tabs[id]?.url?.absoluteString, "https://example.com/a")
        await controller.settleEngineWork()
        XCTAssertNotNil(controller.liveTab(for: id))
    }

    /// `make new tab` in a Space: top of that Space's Today; the window stays where it is.
    func testMakeTabInSpaceWithLocation() throws {
        let (model, windowID) = window()
        let id = try host.makeTab(inSpace: f.work, window: windowID, ScriptTabProperties(url: "https://example.org", location: "pinned"))
        XCTAssertEqual(model.workspace.tabs[id]?.location, .pinned(spaceID: f.work, folderID: nil))
        XCTAssertEqual(model.selectedSpaceID, f.home)
        XCTAssertThrowsError(try host.makeTab(inSpace: UUID(), window: windowID, ScriptTabProperties()))
    }

    func testInvalidURLIsAScriptError() {
        let (_, windowID) = window()
        for bad in ["", "not a url", "javascript:alert(1)", "https:"] {
            XCTAssertThrowsError(try host.makeTab(inWindow: windowID, ScriptTabProperties(url: bad, location: nil)), bad) { error in
                XCTAssertEqual((error as? ScriptingFailure)?.number, -10000)
            }
        }
        XCTAssertThrowsError(try host.setTabURL(f.today1, inWindow: windowID, to: "nope"))
    }

    /// Setting URL loads the address in the tab's page.
    func testSetURLNavigates() async throws {
        let (model, windowID) = window()
        try await model.activate(tabID: f.today1)
        try host.setTabURL(f.today1, inWindow: windowID, to: "https://example.com/next")
        await controller.settleEngineWork()
        let live = try XCTUnwrap(controller.liveTab(for: f.today1))
        let state = await live.currentState()
        XCTAssertEqual(state.url?.absoluteString, "https://example.com/next")
        // A tab without a page keeps the address (TreeOps.updateTabContent).
        try host.setTabURL(f.today2, inWindow: windowID, to: "https://example.com/stored")
        XCTAssertEqual(model.workspace.tabs[f.today2]?.url?.absoluteString, "https://example.com/stored")
    }

    func testSelectSwitchesSpaceAndFocusSelectsSpace() throws {
        let (model, windowID) = window()
        try host.selectTab(f.workTab, inWindow: windowID)
        XCTAssertEqual(model.selectedSpaceID, f.work)
        XCTAssertEqual(model.selectedTabID, f.workTab)
        try host.focusSpace(f.home, inWindow: windowID)
        XCTAssertEqual(model.selectedSpaceID, f.home)
        XCTAssertThrowsError(try host.focusSpace(UUID(), inWindow: windowID))
        XCTAssertThrowsError(try host.selectTab(UUID(), inWindow: windowID))
    }

    /// `close` on a tab is ⌘W: a Today tab is archived, a pinned tab stays.
    func testCloseTab() throws {
        let (model, windowID) = window()
        try host.closeTab(f.today1, inWindow: windowID)
        XCTAssertEqual(model.workspace.tabs[f.today1]?.meta.isTombstone, true)
        XCTAssertTrue(model.workspace.archive.values.contains { $0.url?.absoluteString == "https://today1.example.com" })
        try host.closeTab(f.pinnedTab, inWindow: windowID)
        XCTAssertEqual(model.workspace.tabs[f.pinnedTab]?.meta.isTombstone, false)
        XCTAssertThrowsError(try host.closeTab(f.today1, inWindow: windowID), "already closed")
    }

    func testSetLocationMovesTab() throws {
        let (model, windowID) = window()
        try host.setTabLocation(f.today1, inWindow: windowID, to: "pinned")
        XCTAssertEqual(model.workspace.tabs[f.today1]?.location, .pinned(spaceID: f.home, folderID: nil))
        try host.setTabLocation(f.today1, inWindow: windowID, to: "topApp")
        XCTAssertEqual(model.workspace.tabs[f.today1]?.location, .favorite(profileID: f.profile))
        try host.setTabLocation(f.today1, inWindow: windowID, to: "unpinned")
        XCTAssertEqual(model.workspace.tabs[f.today1]?.location, .today(spaceID: f.home))
        XCTAssertThrowsError(try host.setTabLocation(f.today1, inWindow: windowID, to: "sideways"))
    }

    func testWindowModeRequest() throws {
        XCTAssertEqual(try ScriptingHost.windowRequest(mode: nil, incognito: nil, spaceID: f.home).kind, .newWindow)
        XCTAssertEqual(try ScriptingHost.windowRequest(mode: "incognito", incognito: nil, spaceID: f.home).kind, .incognito)
        XCTAssertEqual(try ScriptingHost.windowRequest(mode: nil, incognito: true, spaceID: f.home).kind, .incognito)
        XCTAssertNil(try ScriptingHost.windowRequest(mode: "incognito", incognito: nil, spaceID: f.home).spaceID)
        XCTAssertThrowsError(try ScriptingHost.windowRequest(mode: "private", incognito: nil, spaceID: nil))
    }

    // MARK: JavaScript gate ([06 §29.4])

    /// Off by default: `execute` fails with the gate's script error and never reaches the page.
    func testExecuteIsRefusedWhileTheGateIsOff() async throws {
        let (_, windowID) = window()
        var ran = false
        host.evaluateJavaScript = { _, _ in ran = true; return "2" }
        XCTAssertFalse(preferences.allowsJavaScriptFromAppleEvents, "default off")
        do {
            _ = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
            XCTFail("execute ran with the gate off")
        } catch let failure as ScriptingFailure {
            XCTAssertEqual(failure, .javaScriptNotAllowed)
            XCTAssertTrue(failure.message.contains("Allow JavaScript from Apple Events"))
        }
        XCTAssertFalse(ran)
    }

    /// On (the menu toggle writes the same preference): the script runs in the tab's page.
    func testExecuteRunsWhenAllowed() async throws {
        let (model, windowID) = window()
        model.allowsJavaScriptFromAppleEvents = true
        var seen: (EngineTabID, String)?
        host.evaluateJavaScript = { tab, script in seen = (tab.id, script); return "2" }
        let result = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
        XCTAssertEqual(result, "2")
        XCTAssertEqual(seen?.1, "1+1")
        XCTAssertEqual(seen?.0, controller.liveTab(for: f.today1)?.id, "a tab without a page gets one first")
        // Turning it off again closes the gate at once.
        model.allowsJavaScriptFromAppleEvents = false
        do {
            _ = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
            XCTFail("execute ran with the gate off")
        } catch {
            XCTAssertEqual(error as? ScriptingFailure, .javaScriptNotAllowed)
        }
    }

    // MARK: execute through the engine (plan B71, [06 §29.3] observed command, result as text)

    /// The page's live FakeTab, made live by a first `execute` (a tab without a page gets one).
    private func liveFakeTab(_ windowID: UUID) async throws -> FakeTab {
        _ = try await host.execute("void 0", onTab: f.today1, inWindow: windowID)
        return try XCTUnwrap(controller.liveTab(for: f.today1) as? FakeTab)
    }

    /// The default runner is the engine's `evaluateJavaScript`; its text goes back unchanged.
    func testExecuteReturnsTheEngineResult() async throws {
        let (_, windowID) = window()
        preferences.allowsJavaScriptFromAppleEvents = true
        let tab = try await liveFakeTab(windowID)
        tab.simulateJavaScriptOutcome(.value(json: #""Example Domain""#))
        let title = try await host.execute("document.title", onTab: f.today1, inWindow: windowID)
        XCTAssertEqual(title, "Example Domain", "strings come back without quotes")
        tab.simulateJavaScriptOutcome(.value(json: "2"))
        let sum = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
        XCTAssertEqual(sum, "2")
        tab.simulateJavaScriptOutcome(.value(json: #"{"a":[1,true]}"#))
        let object = try await host.execute("({a:[1,true]})", onTab: f.today1, inWindow: windowID)
        XCTAssertEqual(object, #"{"a":[1,true]}"#)
        tab.simulateJavaScriptOutcome(.value(json: "null"))
        let null = try await host.execute("null", onTab: f.today1, inWindow: windowID)
        XCTAssertEqual(null, "")
        let evaluated = tab.commands.filter { if case .evaluateJavaScript = $0 { true } else { false } }
        XCTAssertEqual(evaluated.last, .evaluateJavaScript("null"))
        XCTAssertEqual(evaluated.count, 5)
    }

    /// Gate off ([06 §29.4] inferred): the engine is never asked, even with a live page.
    func testExecuteGateOffNeverReachesTheEngine() async throws {
        let (_, windowID) = window()
        preferences.allowsJavaScriptFromAppleEvents = true
        let tab = try await liveFakeTab(windowID)
        preferences.allowsJavaScriptFromAppleEvents = false
        let before = tab.commands
        do {
            _ = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
            XCTFail("execute ran with the gate off")
        } catch {
            XCTAssertEqual(error as? ScriptingFailure, .javaScriptNotAllowed)
        }
        XCTAssertEqual(tab.commands, before)
    }

    /// A script that throws reaches the script as an error carrying the page's exception text.
    func testExecuteReportsThePageException() async throws {
        let (_, windowID) = window()
        preferences.allowsJavaScriptFromAppleEvents = true
        let tab = try await liveFakeTab(windowID)
        tab.simulateJavaScriptOutcome(.failure(.javaScriptException("ReferenceError: x is not defined")))
        do {
            _ = try await host.execute("x", onTab: f.today1, inWindow: windowID)
            XCTFail("expected the exception")
        } catch {
            let failure = try XCTUnwrap(error as? ScriptingFailure)
            XCTAssertEqual(failure, .javaScriptException("ReferenceError: x is not defined"))
            XCTAssertEqual(failure.number, -10000)
            XCTAssertTrue(failure.message.contains("ReferenceError: x is not defined"))
        }
    }

    /// An engine build without the bridge call (a Chromium framework from before B71) says so.
    func testExecuteOnAnEngineWithoutJavaScript() async throws {
        let (_, windowID) = window()
        preferences.allowsJavaScriptFromAppleEvents = true
        let tab = try await liveFakeTab(windowID)
        tab.simulateJavaScriptOutcome(.failure(.unsupported("evaluateJavaScript")))
        do {
            _ = try await host.execute("1+1", onTab: f.today1, inWindow: windowID)
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? ScriptingFailure, .javaScriptUnavailable)
        }
    }

    func testEngineErrorMapping() {
        XCTAssertEqual(ScriptingFailure.javaScript(EngineError.javaScriptException("boom")), .javaScriptException("boom"))
        XCTAssertEqual(ScriptingFailure.javaScript(EngineError.unsupported("evaluateJavaScript")), .javaScriptUnavailable)
        XCTAssertEqual(ScriptingFailure.javaScript(EngineError.tabClosed(EngineTabID(UUID()))).number, -1728)
        XCTAssertEqual(ScriptingFailure.javaScript(ScriptingFailure.javaScriptNotAllowed), .javaScriptNotAllowed)
        XCTAssertEqual(ScriptingFailure.javaScript(EngineError.invalidArgument).number, -10000)
    }

    /// The development-build self test runs only outside the release build and only when asked.
    func testSelfTestIsDevelopmentOnly() {
        let env = [ScriptingSelfTest.environmentKey: "/tmp/smoke.applescript"]
        XCTAssertEqual(ScriptingSelfTest.scriptURL(environment: env, bundleIdentifier: "org.openarc.browser.dev")?.path, "/tmp/smoke.applescript")
        XCTAssertNil(ScriptingSelfTest.scriptURL(environment: env, bundleIdentifier: "org.openarc.browser"))
        XCTAssertNil(ScriptingSelfTest.scriptURL(environment: [:], bundleIdentifier: "org.openarc.browser.dev"))
    }
}
