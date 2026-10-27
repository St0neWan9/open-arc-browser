import Foundation
import AppKit
import OpenArcModel

// The Cocoa scripting classes app/Bundle/OpenArc.sdef names (plan B70, [06 §29.2]). Each is a
// light wrapper over ids: properties and commands look the model up at the moment they run, so
// a reference a script keeps stays valid while its window, Space or tab exists. Objective-C names
// are ours ("OAScriptable…"); the sdef refers to them.
//
// Cocoa scripting calls these on the main thread while it handles an Apple event. The classes are
// main-actor isolated; overrides of nonisolated NSObject members (`objectSpecifier`) hop in with
// `onScriptingThread`.

/// Carries a value into or out of `MainActor.assumeIsolated`.
// @unchecked: made and read on the main thread within one `onScriptingThread` call; it never crosses threads.
struct ScriptingResultBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs `body` on the main actor from a nonisolated override that Cocoa scripting calls on the
/// main thread (Apple events are handled there). Traps if called from another thread.
func onScriptingThread<Value>(_ body: @MainActor () -> Value) -> Value {
    MainActor.assumeIsolated { ScriptingResultBox(value: body()) }.value
}

/// Reports `failure` as the current script command's error.
@MainActor
func reportScriptingFailure(_ failure: ScriptingFailure, on command: NSScriptCommand? = NSScriptCommand.current()) {
    command?.scriptErrorNumber = failure.number
    command?.scriptErrorString = failure.message
}

/// Runs `body`; a thrown `ScriptingFailure` becomes the current command's error.
@MainActor
func runScripting<T>(_ command: NSScriptCommand? = NSScriptCommand.current(), _ body: () throws -> T?) -> T? {
    do {
        return try body()
    } catch let failure as ScriptingFailure {
        reportScriptingFailure(failure, on: command)
    } catch {
        reportScriptingFailure(.failed("\(error)"), on: command)
    }
    return nil
}

// MARK: - Window

/// AppleScript `window` (code WiND).
@MainActor
@objc(OAScriptableWindow)
final class ScriptableWindow: NSObject {
    let windowID: UUID
    let host: ScriptingHost

    init(windowID: UUID, host: ScriptingHost) {
        self.windowID = windowID
        self.host = host
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ScriptableWindow)?.windowID == windowID
    }

    override var hash: Int { windowID.hashValue }

    private var nsWindow: NSWindow? { host.window(withID: windowID)?.window }

    /// `window id "<id>" of application`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        let windowID = self.windowID
        return onScriptingThread { ScriptableWindow.specifier(windowID: windowID) }
    }

    static func specifier(windowID: UUID) -> NSScriptObjectSpecifier? {
        guard let appDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: appDescription, containerSpecifier: nil,
            key: ScriptingKeys.applicationWindows, uniqueID: windowID.uuidString
        )
    }

    // MARK: Elements

    @objc var scriptingTabs: [ScriptableTab] {
        host.tabIDs(inWindow: windowID).map { ScriptableTab(tabID: $0, container: .window(windowID), host: host) }
    }

    @objc(valueInScriptingTabsWithUniqueID:)
    func valueInScriptingTabs(withUniqueID uniqueID: String) -> ScriptableTab? {
        guard let id = ScriptingHost.id(from: uniqueID), host.tabIDs(inWindow: windowID).contains(id) else { return nil }
        return ScriptableTab(tabID: id, container: .window(windowID), host: host)
    }

    @objc var scriptingSpaces: [ScriptableSpace] {
        host.spaceIDs(inWindow: windowID).map { ScriptableSpace(spaceID: $0, windowID: windowID, host: host) }
    }

    @objc(valueInScriptingSpacesWithUniqueID:)
    func valueInScriptingSpaces(withUniqueID uniqueID: String) -> ScriptableSpace? {
        guard let id = ScriptingHost.id(from: uniqueID), host.spaceIDs(inWindow: windowID).contains(id) else { return nil }
        return ScriptableSpace(spaceID: id, windowID: windowID, host: host)
    }

    // MARK: Properties

    @objc var scriptingID: String { windowID.uuidString }
    @objc var scriptingName: String { host.windowName(windowID) }

    @objc var scriptingIndex: Int {
        get { host.windowIndex(windowID) }
        set { host.setWindowIndex(windowID, to: newValue) }
    }

    @objc var scriptingCloseable: Bool { nsWindow?.styleMask.contains(.closable) ?? false }
    @objc var scriptingMinimizable: Bool { nsWindow?.styleMask.contains(.miniaturizable) ?? false }
    @objc var scriptingResizable: Bool { nsWindow?.styleMask.contains(.resizable) ?? false }
    @objc var scriptingZoomable: Bool { nsWindow?.standardWindowButton(.zoomButton)?.isEnabled ?? false }

    @objc var scriptingMinimized: Bool {
        get { nsWindow?.isMiniaturized ?? false }
        set {
            guard let window = nsWindow, window.isMiniaturized != newValue else { return }
            if newValue { window.miniaturize(nil) } else { window.deminiaturize(nil) }
        }
    }

    @objc var scriptingVisible: Bool {
        get { nsWindow?.isVisible ?? false }
        set {
            guard let window = nsWindow, window.isVisible != newValue else { return }
            if newValue { window.orderFront(nil) } else { window.orderOut(nil) }
        }
    }

    @objc var scriptingZoomed: Bool {
        get { nsWindow?.isZoomed ?? false }
        set {
            guard let window = nsWindow, window.isZoomed != newValue else { return }
            window.zoom(nil)
        }
    }

    @objc var scriptingActiveTab: ScriptableTab? {
        host.activeTabID(inWindow: windowID).map { ScriptableTab(tabID: $0, container: .window(windowID), host: host) }
    }

    @objc var scriptingActiveSpace: ScriptableSpace? {
        host.activeSpaceID(inWindow: windowID).map { ScriptableSpace(spaceID: $0, windowID: windowID, host: host) }
    }

    /// Set once, when the window is made ([06 §29.2] observed description); later writes fail.
    @objc var scriptingIncognito: Bool {
        get { host.isIncognito(windowID) }
        set { if newValue != host.isIncognito(windowID) { reportScriptingFailure(Self.modeIsFixed) } }
    }

    @objc var scriptingMode: String {
        get { (host.isIncognito(windowID) ? ScriptWindowMode.incognito : .normal).rawValue }
        set { if newValue != scriptingMode { reportScriptingFailure(Self.modeIsFixed) } }
    }

    static let modeIsFixed = ScriptingFailure.notModifiable("A window's mode can only be set when the window is made.")

    // MARK: Commands

    @objc(handleCloseScriptCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        runScripting(command) { try host.closeWindow(windowID) } ?? nil
    }
}

// MARK: - Space

/// AppleScript `space` (code sPaC).
@MainActor
@objc(OAScriptableSpace)
final class ScriptableSpace: NSObject {
    let spaceID: UUID
    /// The window the script reached the Space through; commands act in that window.
    let windowID: UUID
    let host: ScriptingHost

    init(spaceID: UUID, windowID: UUID, host: ScriptingHost) {
        self.spaceID = spaceID
        self.windowID = windowID
        self.host = host
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ScriptableSpace else { return false }
        return other.spaceID == spaceID && other.windowID == windowID
    }

    override var hash: Int { spaceID.hashValue ^ windowID.hashValue }

    /// `space id "<id>" of window id "<id>"`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        let (spaceID, windowID) = (self.spaceID, self.windowID)
        return onScriptingThread { ScriptableSpace.specifier(spaceID: spaceID, windowID: windowID) }
    }

    static func specifier(spaceID: UUID, windowID: UUID) -> NSScriptObjectSpecifier? {
        guard let container = ScriptableWindow.specifier(windowID: windowID),
              let description = NSScriptClassDescription(for: ScriptableWindow.self) else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: description, containerSpecifier: container,
            key: ScriptingKeys.spaces, uniqueID: spaceID.uuidString
        )
    }

    @objc var scriptingTabs: [ScriptableTab] {
        tabIDs.map { ScriptableTab(tabID: $0, container: .space(spaceID, window: windowID), host: host) }
    }

    @objc(valueInScriptingTabsWithUniqueID:)
    func valueInScriptingTabs(withUniqueID uniqueID: String) -> ScriptableTab? {
        guard let id = ScriptingHost.id(from: uniqueID), tabIDs.contains(id) else { return nil }
        return ScriptableTab(tabID: id, container: .space(spaceID, window: windowID), host: host)
    }

    private var tabIDs: [UUID] {
        guard let model = try? host.model(forWindow: windowID) else { return [] }
        return ScriptingHost.tabIDs(inSpace: spaceID, of: model.workspace)
    }

    @objc var scriptingID: String { spaceID.uuidString }
    @objc var scriptingTitle: String { host.spaceTitle(spaceID, inWindow: windowID) }

    @objc(handleFocusScriptCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        runScripting(command) { try host.focusSpace(spaceID, inWindow: windowID) } ?? nil
    }
}

// MARK: - Tab

/// AppleScript `tab` (code tAbB).
@MainActor
@objc(OAScriptableTab)
final class ScriptableTab: NSObject {
    /// What the script reached the tab through.
    enum Container: Equatable, Sendable {
        case window(UUID)
        case space(UUID, window: UUID)

        var windowID: UUID {
            switch self {
            case .window(let id), .space(_, let id): return id
            }
        }
    }

    let tabID: UUID
    let container: Container
    let host: ScriptingHost
    private var windowID: UUID { container.windowID }

    init(tabID: UUID, container: Container, host: ScriptingHost) {
        self.tabID = tabID
        self.container = container
        self.host = host
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ScriptableTab else { return false }
        return other.tabID == tabID && other.container == container
    }

    override var hash: Int { tabID.hashValue }

    /// `tab id "<id>" of window id "<id>"`, or `… of space id "<id>" of window id "<id>"`.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        let (tabID, container) = (self.tabID, self.container)
        return onScriptingThread { ScriptableTab.specifier(tabID: tabID, container: container) }
    }

    static func specifier(tabID: UUID, container: Container) -> NSScriptObjectSpecifier? {
        let containerSpecifier: NSScriptObjectSpecifier?
        let containerDescription: NSScriptClassDescription?
        switch container {
        case .window(let windowID):
            containerSpecifier = ScriptableWindow.specifier(windowID: windowID)
            containerDescription = NSScriptClassDescription(for: ScriptableWindow.self)
        case .space(let spaceID, let windowID):
            containerSpecifier = ScriptableSpace.specifier(spaceID: spaceID, windowID: windowID)
            containerDescription = NSScriptClassDescription(for: ScriptableSpace.self)
        }
        guard let containerSpecifier, let containerDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: containerDescription, containerSpecifier: containerSpecifier,
            key: ScriptingKeys.tabs, uniqueID: tabID.uuidString
        )
    }

    // MARK: Properties

    @objc var scriptingID: String { tabID.uuidString }
    @objc var scriptingTitle: String { host.tabTitle(tabID, inWindow: windowID) }
    @objc var scriptingLoading: Bool { host.tabIsLoading(tabID, inWindow: windowID) }

    @objc var scriptingURL: String {
        get { host.tabURL(tabID, inWindow: windowID) }
        set { _ = runScripting { try host.setTabURL(tabID, inWindow: windowID, to: newValue) } }
    }

    @objc var scriptingLocation: String {
        get { host.tabLocation(tabID, inWindow: windowID) }
        set { _ = runScripting { try host.setTabLocation(tabID, inWindow: windowID, to: newValue) } }
    }

    // MARK: Commands

    @objc(handleSelectScriptCommand:)
    func handleSelect(_ command: NSScriptCommand) -> Any? {
        runScripting(command) { try host.selectTab(tabID, inWindow: windowID) } ?? nil
    }

    @objc(handleGoBackScriptCommand:)
    func handleGoBack(_ command: NSScriptCommand) -> Any? { page(.goBack, command) }

    @objc(handleGoForwardScriptCommand:)
    func handleGoForward(_ command: NSScriptCommand) -> Any? { page(.goForward, command) }

    @objc(handleReloadScriptCommand:)
    func handleReload(_ command: NSScriptCommand) -> Any? { page(.reload, command) }

    @objc(handleStopScriptCommand:)
    func handleStop(_ command: NSScriptCommand) -> Any? { page(.stop, command) }

    private func page(_ pageCommand: ScriptingHost.PageCommand, _ command: NSScriptCommand) -> Any? {
        runScripting(command) { try host.perform(pageCommand, onTab: tabID, inWindow: windowID) } ?? nil
    }

    @objc(handleCloseScriptCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        runScripting(command) { try host.closeTab(tabID, inWindow: windowID) } ?? nil
    }

    /// `execute`: the reply waits for the page (`suspendExecution`), so the script gets the result.
    @objc(handleExecuteScriptCommand:)
    func handleExecute(_ command: NSScriptCommand) -> Any? {
        guard let script = command.evaluatedArguments?[ScriptingKeys.javaScriptArgument] as? String else {
            reportScriptingFailure(.failed("execute needs a javascript parameter."), on: command)
            return nil
        }
        let (host, tabID, windowID) = (self.host, self.tabID, self.windowID)
        // Refuse at once while the gate is closed, without suspending the event.
        if let model = try? host.model(forWindow: windowID), !host.allowsJavaScript(for: model.controller) {
            reportScriptingFailure(.javaScriptNotAllowed, on: command)
            return nil
        }
        command.suspendExecution()
        Task { @MainActor in
            do {
                let result = try await host.execute(script, onTab: tabID, inWindow: windowID)
                command.resumeExecution(withResult: result)
            } catch {
                reportScriptingFailure(error as? ScriptingFailure ?? .failed("\(error)"), on: command)
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }
}

/// Cocoa keys the sdef and the specifiers share.
enum ScriptingKeys {
    static let applicationWindows = "openArcScriptWindows"
    static let applicationLittleArcTabs = "openArcScriptLittleArcTabs"
    static let tabs = "scriptingTabs"
    static let spaces = "scriptingSpaces"
    /// The `javascript` parameter of `execute`.
    static let javaScriptArgument = "script"
    /// Property keys `make … with properties` reads.
    static let url = "scriptingURL"
    static let location = "scriptingLocation"
    static let mode = "scriptingMode"
    static let incognito = "scriptingIncognito"
}

// MARK: - Application

/// The application's elements and properties ([06 §29.2] observed). KVC accessors on
/// `NSApplication`, which the sdef's application class names.
extension NSApplication {
    @objc var openArcScriptWindows: [ScriptableWindow] {
        let host = ScriptingHost.shared
        return host.windows.map { ScriptableWindow(windowID: $0.id, host: host) }
    }

    @objc(valueInOpenArcScriptWindowsWithUniqueID:)
    func valueInOpenArcScriptWindows(withUniqueID uniqueID: String) -> ScriptableWindow? {
        let host = ScriptingHost.shared
        guard let id = ScriptingHost.id(from: uniqueID), host.window(withID: id) != nil else { return nil }
        return ScriptableWindow(windowID: id, host: host)
    }

    /// Write-only element ([06 §29.2] observed): only `make new tab` uses it. Reading lists nothing.
    @objc var openArcScriptLittleArcTabs: [ScriptableTab] { [] }

    @objc var openArcScriptName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? AppIdentity.displayName
    }

    @objc var openArcScriptFrontmost: Bool { isActive }

    @objc var openArcScriptVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
