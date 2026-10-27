import Foundation
import AppKit
import OpenArcModel
import OpenArcEngine

// What the AppleScript properties and commands do (plan B70, [06 §29]). Everything here works on
// ids: window ids from `ScriptingHost`, Space and tab ids are the model's UUIDs (as text in
// scripts). Tree changes go through `TreeOps`, either through an existing sidebar intent or in a
// `WorkspaceController.mutate`. Behavior marked inferred is ours: the spec only recorded the
// dictionary ([06 §29.3]: "the commands' actual effects and error codes were not tested").

/// Starting values given with `make new … with properties {…}`.
struct ScriptTabProperties: Equatable {
    var url: String?
    var location: String?
}

/// The text of a tab's `location` property. [06 §29.2] observed values; their meaning (favorites,
/// pinned area, Today) is inferred.
enum ScriptTabLocation: String, CaseIterable {
    case topApp
    case pinned
    case unpinned

    init(_ location: TabLocation) {
        switch location {
        case .favorite: self = .topApp
        case .pinned: self = .pinned
        case .today: self = .unpinned
        }
    }
}

/// The text of a window's `mode` property. [06 §29.2] observed values.
enum ScriptWindowMode: String {
    case normal
    case incognito
}

extension ScriptingHost {

    // MARK: Lookup

    /// The model of browser window `id`, or a "no such object" failure.
    func model(forWindow id: UUID) throws -> ShellModel {
        guard let model = window(withID: id)?.model else { throw ScriptingFailure.noSuchObject("window") }
        return model
    }

    /// A live (not deleted) tab of the window's workspace.
    func tab(_ tabID: UUID, inWindow windowID: UUID) throws -> (model: ShellModel, tab: TabNode) {
        let model = try model(forWindow: windowID)
        guard let tab = model.workspace.tabs[tabID], !tab.meta.isTombstone else { throw ScriptingFailure.noSuchObject("tab") }
        return (model, tab)
    }

    /// Parses a script's id text into a UUID (ids are UUID strings, case-insensitive).
    static func id(from text: Any?) -> UUID? {
        guard let text = text as? String else { return nil }
        return UUID(uuidString: text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Elements

    /// Spaces a window can show, in dock order ([06 §29.2] observed: "the Spaces this window can
    /// reach"). An incognito window reaches its one in-memory Space.
    func spaceIDs(inWindow windowID: UUID) -> [UUID] {
        guard let model = try? model(forWindow: windowID) else { return [] }
        return model.workspace.allLiveSpaces.map(\.id)
    }

    /// A window's tabs: those of the Space it shows. [06 §29.2] unknown which tabs the element
    /// holds; ours (inferred): what the sidebar lists for that Space, top to bottom.
    func tabIDs(inWindow windowID: UUID) -> [UUID] {
        guard let model = try? model(forWindow: windowID), let spaceID = model.selectedSpaceID else { return [] }
        return Self.tabIDs(inSpace: spaceID, of: model.workspace)
    }

    /// A Space's tabs in sidebar order: the favorites of its Profile, the pinned area depth first
    /// (folders open or not), then Today. inferred.
    static func tabIDs(inSpace spaceID: UUID, of workspace: WorkspaceState) -> [UUID] {
        guard let space = workspace.spaces[spaceID], !space.meta.isTombstone else { return [] }
        func pinned(_ folderID: UUID?) -> [UUID] {
            workspace.pinnedChildren(spaceID: spaceID, folderID: folderID).flatMap { item -> [UUID] in
                switch item {
                case .tab(let tab): return [tab.id]
                case .folder(let folder): return pinned(folder.id)
                }
            }
        }
        return workspace.favorites(profileID: space.profileID).map(\.id) + pinned(nil) + workspace.today(spaceID: spaceID).map(\.id)
    }

    // MARK: Window properties

    func activeTabID(inWindow windowID: UUID) -> UUID? {
        guard let model = try? model(forWindow: windowID), let id = model.selectedTabID,
              model.workspace.tabs[id].map({ !$0.meta.isTombstone }) == true else { return nil }
        return id
    }

    func activeSpaceID(inWindow windowID: UUID) -> UUID? {
        (try? model(forWindow: windowID))?.selectedSpaceID
    }

    /// The window's full title: its selected tab's title, else the window's own. inferred.
    func windowName(_ windowID: UUID) -> String {
        guard let entry = window(withID: windowID) else { return "" }
        if let tabID = activeTabID(inWindow: windowID) {
            let title = tabTitle(tabID, inWindow: windowID)
            if !title.isEmpty { return title }
        }
        return entry.window?.title ?? AppIdentity.displayName
    }

    /// 1-based place in the front-to-back order.
    func windowIndex(_ windowID: UUID) -> Int {
        (windows.firstIndex { $0.id == windowID } ?? 0) + 1
    }

    /// Moves the window to `index` in the front-to-back order: 1 brings it to the front (inferred,
    /// [06 §29.2] marks `index` writable without saying what it does).
    func setWindowIndex(_ windowID: UUID, to index: Int) {
        let order = windows
        guard let window = order.first(where: { $0.id == windowID })?.window else { return }
        if index <= 1 {
            BrowserWindowObserver.bringToFront(window)
            return
        }
        let others = order.filter { $0.id != windowID }
        let aboveIndex = min(index, others.count) - 1
        guard others.indices.contains(aboveIndex), let above = others[aboveIndex].window else { return }
        window.order(.below, relativeTo: above.windowNumber)
    }

    func isIncognito(_ windowID: UUID) -> Bool {
        (try? model(forWindow: windowID))?.isIncognito ?? false
    }

    // MARK: Tab properties

    /// The tab's full title: a custom name, else the page's title, else the stored one.
    func tabTitle(_ tabID: UUID, inWindow windowID: UUID) -> String {
        guard let (model, tab) = try? tab(tabID, inWindow: windowID) else { return "" }
        if let custom = tab.customTitle { return custom }
        if let live = model.controller.liveState(for: tabID)?.title, !live.isEmpty { return live }
        return tab.title
    }

    /// The tab's address: the live page's, else the stored one.
    func tabURL(_ tabID: UUID, inWindow windowID: UUID) -> String {
        guard let (model, tab) = try? tab(tabID, inWindow: windowID) else { return "" }
        return (model.controller.liveState(for: tabID)?.url ?? tab.url ?? tab.pinnedURL)?.absoluteString ?? ""
    }

    func tabIsLoading(_ tabID: UUID, inWindow windowID: UUID) -> Bool {
        guard let (model, _) = try? tab(tabID, inWindow: windowID) else { return false }
        return model.controller.liveState(for: tabID)?.isLoading ?? false
    }

    func tabLocation(_ tabID: UUID, inWindow windowID: UUID) -> String {
        guard let (_, tab) = try? tab(tabID, inWindow: windowID) else { return "" }
        return ScriptTabLocation(tab.location).rawValue
    }

    func spaceTitle(_ spaceID: UUID, inWindow windowID: UUID) -> String {
        guard let model = try? model(forWindow: windowID), let space = model.workspace.spaces[spaceID], !space.meta.isTombstone else { return "" }
        return space.name
    }

    /// A URL a script gave: absolute, with a scheme the engine loads. [06 §29.3] observed that an
    /// invalid URL gets its own error. `javascript:` is refused like the bridge refuses it.
    static func parseURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              scheme != "javascript", url.absoluteString.count > scheme.count + 1 else {
            throw ScriptingFailure.invalidURL(text)
        }
        return url
    }

    /// Setting `URL` loads it in the tab ([06 §29.2] observed: "writing it navigates"). A tab with
    /// no page yet keeps the address and loads it when shown.
    func setTabURL(_ tabID: UUID, inWindow windowID: UUID, to text: String) throws {
        let (model, _) = try tab(tabID, inWindow: windowID)
        let url = try Self.parseURL(text)
        let controller = model.controller
        if let live = controller.liveTab(for: tabID) {
            controller.enqueueTabCommand(live) { try? await $0.load(url) }
            return
        }
        try controller.mutate(origin: nil) { ws in
            let title = ws.tabs[tabID]?.title ?? ""
            return try TreeOps.updateTabContent(ws, id: tabID, url: url, title: title, faviconURL: nil, now: controller.now())
        }
    }

    /// Moves the tab to the favorites, the pinned area or Today. [06 §29.2] unknown whether Arc
    /// allows it after creation; ours does (inferred). Uses the sidebar's Pin / Unpin / Add to
    /// Favorites intents.
    func setTabLocation(_ tabID: UUID, inWindow windowID: UUID, to text: String) throws {
        let (model, tab) = try tab(tabID, inWindow: windowID)
        guard let target = ScriptTabLocation(rawValue: text) else {
            throw ScriptingFailure.failed("“\(text)” is not a tab location. Use \(ScriptTabLocation.allCases.map { "“\($0.rawValue)”" }.joined(separator: ", ")).")
        }
        guard target != ScriptTabLocation(tab.location) else { return }
        if model.isIncognito { throw ScriptingFailure.notModifiable("An incognito window has no favorites or pinned tabs.") }
        let sidebar = model.sidebar
        switch target {
        case .topApp: sidebar.addFavorite(tabID)
        case .pinned:
            if case .favorite = tab.location { sidebar.unpinTab(tabID) }
            sidebar.pinTab(tabID)
        case .unpinned: sidebar.unpinTab(tabID)
        }
        if let error = sidebar.lastError { throw ScriptingFailure.failed("The tab could not move: \(error)") }
    }

    // MARK: Commands

    /// `select`: shows the tab in its window, switching to its Space first ([06 §29.3] inferred).
    /// A tab another window already shows brings that window forward instead (the sidebar's rule).
    func selectTab(_ tabID: UUID, inWindow windowID: UUID) throws {
        let (model, tab) = try tab(tabID, inWindow: windowID)
        model.library.exit()
        if let spaceID = tab.location.spaceID, spaceID != model.selectedSpaceID { model.selectSpace(spaceID) }
        model.sidebar.selectTab(tabID)
    }

    /// `focus`: the window shows the Space. [06 §29.3] observed ("switch to that Space").
    func focusSpace(_ spaceID: UUID, inWindow windowID: UUID) throws {
        let model = try model(forWindow: windowID)
        guard model.workspace.spaces[spaceID].map({ !$0.meta.isTombstone }) == true else { throw ScriptingFailure.noSuchObject("Space") }
        model.library.exit()
        model.selectSpace(spaceID)
    }

    /// `close` on a tab does what ⌘W does: a Today tab is archived, a pinned tab or favorite is
    /// unloaded and stays (inferred: a script must not delete the user's pins).
    func closeTab(_ tabID: UUID, inWindow windowID: UUID) throws {
        let (model, _) = try tab(tabID, inWindow: windowID)
        model.sidebar.closeOrUnloadTab(tabID)
    }

    func closeWindow(_ windowID: UUID) throws {
        guard let entry = window(withID: windowID), entry.model != nil else { throw ScriptingFailure.noSuchObject("window") }
        entry.window?.performClose(nil)
    }

    enum PageCommand {
        case goBack, goForward, reload, stop
    }

    /// go back / go forward / reload / stop on the tab's page. A tab without a page does nothing
    /// ([06 §29.3] observed "if it can").
    func perform(_ command: PageCommand, onTab tabID: UUID, inWindow windowID: UUID) throws {
        let (model, _) = try tab(tabID, inWindow: windowID)
        guard let live = model.controller.liveTab(for: tabID) else { return }
        model.controller.enqueueTabCommand(live) { tab in
            switch command {
            case .goBack: try? await tab.goBack()
            case .goForward: try? await tab.goForward()
            case .reload: try? await tab.reload()
            case .stop: try? await tab.stopLoading()
            }
        }
    }

    /// `execute`: runs `script` in the tab's page and returns the result as text. Refused unless
    /// View ▸ Developer ▸ Allow JavaScript from Apple Events is on ([06 §29.4] inferred). A tab
    /// without a page gets one first.
    func execute(_ script: String, onTab tabID: UUID, inWindow windowID: UUID) async throws -> String {
        let (model, _) = try tab(tabID, inWindow: windowID)
        guard allowsJavaScript(for: model.controller) else { throw ScriptingFailure.javaScriptNotAllowed }
        let controller = model.controller
        if controller.liveTab(for: tabID) == nil {
            try? await controller.ensureLive(tabID, fallbackProfileID: model.sidebar.currentProfileID)
        }
        guard let live = controller.liveTab(for: tabID) else { throw ScriptingFailure.failed("The tab has no web page.") }
        do {
            return try await evaluateJavaScript(live, script)
        } catch {
            throw ScriptingFailure.javaScript(error)
        }
    }

    // MARK: make

    /// `make new tab` told to a window: a new tab at the top of Today in the Space it shows,
    /// selected (like ⌘T, [06 §13] observed placement). Returns the tab id.
    func makeTab(inWindow windowID: UUID, _ properties: ScriptTabProperties) throws -> UUID {
        let model = try model(forWindow: windowID)
        let url = try properties.url.map(Self.parseURL)
        model.library.exit()
        guard let id = model.sidebar.newTab(url: url, title: url?.host ?? "New Tab") else {
            throw ScriptingFailure.failed("The window has no Space to open a tab in.")
        }
        try applyLocation(properties, to: id, inWindow: windowID)
        return id
    }

    /// `make new tab` told to a Space: a new tab at the top of that Space's Today, without
    /// switching the window (inferred). Returns the tab id.
    func makeTab(inSpace spaceID: UUID, window windowID: UUID, _ properties: ScriptTabProperties) throws -> UUID {
        let model = try model(forWindow: windowID)
        guard model.workspace.spaces[spaceID].map({ !$0.meta.isTombstone }) == true else { throw ScriptingFailure.noSuchObject("Space") }
        let url = try properties.url.map(Self.parseURL)
        let controller = model.controller
        let id = controller.makeID()
        try controller.mutate(origin: nil) {
            try TreeOps.openTab($0, id: id, spaceID: spaceID, url: url, title: url?.host ?? "New Tab", now: controller.now())
        }
        try applyLocation(properties, to: id, inWindow: windowID)
        return id
    }

    private func applyLocation(_ properties: ScriptTabProperties, to id: UUID, inWindow windowID: UUID) throws {
        guard let location = properties.location else { return }
        try setTabLocation(id, inWindow: windowID, to: location)
    }

    /// `make new tab` told to the application opens a Little Arc window on the URL ([06 §29.2]
    /// observed description). Without a URL it opens an empty Little Arc (inferred).
    func makeLittleArcTab(_ properties: ScriptTabProperties) throws {
        guard let controller = appController else { throw ScriptingFailure.failed("Open Arc has no browser window yet.") }
        let url = try properties.url.map(Self.parseURL)
        guard let open = controller.openLittleArcWindow else { throw ScriptingFailure.failed("Little Arc cannot open now.") }
        let id = controller.issueLittleArcWindowID()
        if let url { controller.littleArcLaunchURLs[id] = url }
        open(id)
    }

    /// The window request `make new window` opens: incognito when `mode` is "incognito" or
    /// `incognito` is true ([06 §29.2] observed: set once, when the window is made).
    static func windowRequest(mode: String?, incognito: Bool?, spaceID: UUID?) throws -> BrowserWindowRequest {
        if let mode, ScriptWindowMode(rawValue: mode) == nil {
            throw ScriptingFailure.failed("“\(mode)” is not a window mode. Use “normal” or “incognito”.")
        }
        let wantsIncognito = mode.flatMap(ScriptWindowMode.init(rawValue:)) == .incognito || incognito == true
        return BrowserWindowRequest(kind: wantsIncognito ? .incognito : .newWindow, spaceID: wantsIncognito ? nil : spaceID)
    }

    /// Opens a browser window for `make new window` and reports its id once it registered (nil
    /// after the timeout).
    func makeWindow(mode: String?, incognito: Bool?, completion: @escaping (Result<UUID?, ScriptingFailure>) -> Void) {
        guard let controller = appController, let open = controller.openBrowserWindow else {
            completion(.failure(.failed("Open Arc cannot open a window now.")))
            return
        }
        let request: BrowserWindowRequest
        do {
            request = try Self.windowRequest(mode: mode, incognito: incognito, spaceID: controller.activeSpaceID)
        } catch let failure as ScriptingFailure {
            completion(.failure(failure))
            return
        } catch {
            completion(.failure(.failed("\(error)")))
            return
        }
        waitForNewWindow(timeout: ScriptingTiming.newWindowTimeout) { entry in completion(.success(entry?.id)) }
        open(request)
    }
}

/// Timing of scripting commands. Our own values.
enum ScriptingTiming {
    /// How long `make new window` waits for the new window before it returns without a reference.
    static let newWindowTimeout: TimeInterval = 5
}
