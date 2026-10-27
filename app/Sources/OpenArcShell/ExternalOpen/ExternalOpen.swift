import Foundation
import AppKit
import SwiftUI
import OpenArcModel

// Links and files opened from other apps (plan D2): a link clicked in Mail, `open https://…`,
// Finder ▸ Open With for an HTML or PDF file. The bundle declares the http/https URL types and
// the document types (`app/Bundle/Info.plist`, D1); LaunchServices hands them to
// `NSApplicationDelegate.application(_:open:)`.
//
// Routing (all inferred, the spec records no external-link behavior apart from the Links
// settings in [03 §Links]): every accepted URL becomes a new Today tab at the top of the current
// Space of the frontmost normal browser window (the one used last; incognito windows never take
// external links), and is selected. With no browser window open, one is opened and gets the URLs.
// With the Links setting "Open links from other apps in Little Arc" on ([03 §Links] observed
// toggle; B24), a web link opens in a new Little Arc window instead, already expanded on the page;
// local files still open as Today tabs (inferred).
// Air Traffic Control rules (plan B52, [06 §25]) plug in through `ExternalLinkRouting`
// (`AirTrafficControlRouter`).

/// What an external URL opens as.
public enum ExternalOpenDestination: Equatable, Sendable {
    /// A new Today tab in the current Space of the frontmost normal window. The default.
    case frontmostWindow
    /// A new Today tab in this Space, shown in the frontmost normal window (Air Traffic Control
    /// "open in Space"; plan E5).
    case space(UUID)
    /// A new Little Arc window, already expanded and loading the URL (B24). Only for web links: a
    /// local file routed here opens as `frontmostWindow` instead (inferred).
    case littleArc
}

/// Picks where an external URL opens. The hook for Air Traffic Control (plan E5): its rules
/// replace `DefaultExternalLinkRouter` on the controller.
@MainActor
public protocol ExternalLinkRouting {
    func destination(for url: URL, in workspace: WorkspaceState) -> ExternalOpenDestination
}

/// No rules: web links open in Little Arc when the Links setting says so ([03 §Links] observed
/// toggle), everything else in the frontmost window's current Space.
public struct DefaultExternalLinkRouter: ExternalLinkRouting {
    /// Where the Links setting is read, on every link (it may change while the app runs). nil:
    /// the setting is treated as off.
    private let preferences: AppPreferences?

    public init(preferences: AppPreferences? = nil) {
        self.preferences = preferences
    }

    public func destination(for url: URL, in workspace: WorkspaceState) -> ExternalOpenDestination {
        if ExternalOpen.isWebLink(url), preferences?.opensExternalLinksInLittleArc == true { return .littleArc }
        return .frontmostWindow
    }
}

/// Which incoming URLs the app opens.
public enum ExternalOpen {
    /// Web schemes, matching `CFBundleURLTypes` in Info.plist.
    public static let webSchemes: Set<String> = ["http", "https"]

    /// Local file extensions, matching `CFBundleDocumentTypes` in Info.plist (HTML, XHTML, web
    /// archive, PDF).
    public static let fileExtensions: Set<String> = ["html", "htm", "shtml", "xhtml", "xht", "webarchive", "pdf"]

    /// Whether `url` is a web link or a local document the app opens.
    public static func accepts(_ url: URL) -> Bool {
        if url.isFileURL { return fileExtensions.contains(url.pathExtension.lowercased()) }
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme) else { return false }
        return url.host?.isEmpty == false
    }

    /// Whether `url` is an http/https link (not a local file).
    public static func isWebLink(_ url: URL) -> Bool {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased() else { return false }
        return webSchemes.contains(scheme)
    }

    /// The accepted URLs of `urls`, in order.
    public static func filter(_ urls: [URL]) -> [URL] {
        urls.filter(accepts)
    }

    /// Placeholder title until the page reports its own: the host, or the file name.
    static func title(for url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        return url.host ?? url.absoluteString
    }
}

/// Buffers URLs that arrive before the scene's controller exists (a link that launches the app
/// reaches the app delegate before SwiftUI builds the scene), then hands them over in order.
@MainActor
public final class ExternalOpenInbox {
    private var buffered: [URL] = []
    private var handler: (([URL]) -> Void)?
    /// Opens a browser window when URLs are still waiting after launch (no window appeared, e.g.
    /// the app was launched by a link and SwiftUI opened no window). Installed by
    /// `ExternalOpenCommands`, where SwiftUI's `openWindow` exists without any window.
    var fallbackWindowOpener: (() -> Void)?
    private var didRequestFallbackWindow = false

    public init() {}

    /// Whether URLs are waiting for the controller.
    public var isWaiting: Bool { handler == nil && !buffered.isEmpty }

    /// Called once after launch: opens a window if URLs are still waiting for one. The window
    /// connects the inbox when it appears. inferred.
    public func openWindowIfStillWaiting() {
        guard isWaiting, !didRequestFallbackWindow, let open = fallbackWindowOpener else { return }
        didRequestFallbackWindow = true
        open()
    }

    /// URLs from the system. Delivered now if a handler is connected, else kept.
    public func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let handler { handler(urls) } else { buffered.append(contentsOf: urls) }
    }

    /// Connects the receiver (the app's `WorkspaceController`) and delivers what was kept.
    public func connect(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        guard !buffered.isEmpty else { return }
        let urls = buffered
        buffered.removeAll()
        handler(urls)
    }
}

/// The app delegate: receives URLs and files opened from other apps, and runs the quit sequence
/// (B27). The executable installs it with `@NSApplicationDelegateAdaptor` and passes `inbox` and
/// `termination` to `OpenArcScene`.
@MainActor
public final class OpenArcAppDelegate: NSObject, NSApplicationDelegate {
    public let inbox = ExternalOpenInbox()
    /// Flushes the store and shuts the engine down before the app exits, without blocking the
    /// main thread. The scene attaches its controller.
    public let termination = AppTermination()

    override public init() {
        super.init()
    }

    /// Links (http/https) and documents (HTML, PDF) from LaunchServices, in the order given.
    public func application(_ application: NSApplication, open urls: [URL]) {
        inbox.receive(urls)
    }

    /// The first browser window normally appears right after launch and connects the inbox. If
    /// links are still waiting a moment later, no window came: open one for them.
    /// ⌘Q, logout, an update relaunch: answer later, once the quit sequence finished (B27).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.shouldTerminate(sender)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let inbox = self.inbox
        DispatchQueue.main.asyncAfter(deadline: .now() + ExternalOpenTiming.fallbackWindowDelay) {
            MainActor.assumeIsolated { inbox.openWindowIfStillWaiting() }
        }
    }
}

enum ExternalOpenTiming {
    /// How long after launch the delegate waits for the first window before opening one for
    /// waiting links. Our own value.
    static let fallbackWindowDelay: TimeInterval = 0.5
}

/// Gives the inbox a window opener that works without any window (menu commands are built at
/// launch). Adds no menu item.
/// Also gives the controller its Little Arc window opener (B24) and its browser window opener
/// (B29), so both work while no browser window is open.
struct ExternalOpenCommands: Commands {
    let inbox: ExternalOpenInbox?
    let controller: WorkspaceController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let open = openWindow
        // Plain stored properties: setting them while SwiftUI evaluates the commands publishes nothing.
        let _ = inbox?.fallbackWindowOpener = { open(id: BrowserWindowScene.id, value: BrowserWindowRequest(kind: .restore)) }
        let _ = controller.openLittleArcWindow = { id in open(id: LittleArcScene.id, value: id) }
        // Browser windows too: an opener taken from a window's view may outlive that window (B29).
        let _ = controller.installWindowOpener(sceneLevel: true) { request in open(id: BrowserWindowScene.id, value: request) }
        // An empty group, not `EmptyCommands()`: SwiftUI never evaluates a body that is only
        // `EmptyCommands()`, so the openers above were never installed and a link that launched
        // the app opened no window (B19, cold start). The group adds no menu item.
        CommandGroup(after: .appInfo) {}
    }
}

// MARK: - Controller

extension WorkspaceController {
    /// Opens links and files from other apps. Unsupported URLs are dropped. Web links the router
    /// sends to Little Arc each open a new Little Arc window (B24). The rest: with a normal
    /// browser window open, they open in the frontmost one (see `ShellModel.openExternalURLs`) and
    /// it comes to the front. Without one, they wait for the next window to register; a window is
    /// requested unless one is already on its way (launch: the scene opens the first window
    /// itself, before the opener exists).
    public func openExternal(_ urls: [URL]) {
        let router = externalLinkRouter
        var accepted: [URL] = []
        for url in ExternalOpen.filter(urls) {
            if router.destination(for: url, in: workspace) == .littleArc, openInLittleArc(url) { continue }
            accepted.append(url)
        }
        guard !accepted.isEmpty else { return }
        if let window = activeWindow {
            deliverExternal(accepted, to: window)
            return
        }
        let windowAlreadyRequested = !pendingExternalURLs.isEmpty
        pendingExternalURLs.append(contentsOf: accepted)
        if !windowAlreadyRequested, let open = openBrowserWindow {
            // Same as a Dock click with no window: the last closed window's Space. inferred.
            open(BrowserWindowRequest(kind: .restore))
        }
    }

    /// A browser window registered: hands it the URLs that were waiting for one.
    func deliverPendingExternalURLs(to window: ShellModel) {
        guard !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        deliverExternal(urls, to: window)
    }

    /// Opens a web link in a new Little Arc window, already expanded on the page (B24). Returns
    /// false when it cannot (a local file, or no window opener installed yet); the caller then
    /// opens it as a Today tab. inferred.
    private func openInLittleArc(_ url: URL) -> Bool {
        guard ExternalOpen.isWebLink(url), let open = openLittleArcWindow else { return false }
        let id = issueLittleArcWindowID()
        littleArcLaunchURLs[id] = url
        open(id)
        return true
    }

    /// The URL a new Little Arc window opens with, or nil (a plain ⌥⌘N window, or a window macOS
    /// restored). Consumed: asking again returns nil.
    func takeLittleArcLaunchURL(for windowID: UUID) -> URL? {
        littleArcLaunchURLs.removeValue(forKey: windowID)
    }

    private func deliverExternal(_ urls: [URL], to window: ShellModel) {
        let router = externalLinkRouter
        let routed = urls.map { (url: $0, destination: router.destination(for: $0, in: workspace)) }
        window.openExternalURLs(routed)
        window.focusWindow?()
    }
}

// MARK: - Window

extension ShellModel {
    /// Opens each URL as a new Today tab at the top of its destination Space, in order, and selects
    /// it (so the last one ends up selected and on top). The window leaves the Library and closes
    /// its command bar first so the new tab is on screen. inferred. Returns the new tab ids.
    @discardableResult
    func openExternalURLs(_ routed: [(url: URL, destination: ExternalOpenDestination)]) -> [UUID] {
        guard !routed.isEmpty else { return [] }
        library.exit()
        dismissCommandBar()
        var opened: [UUID] = []
        for (url, destination) in routed {
            // `.littleArc` only reaches a window when the Little Arc window could not open (a file,
            // or no opener): it opens here like `.frontmostWindow`.
            if case .space(let spaceID) = destination { sidebar.selectSpace(spaceID) }
            if let id = sidebar.newTab(url: url, title: ExternalOpen.title(for: url)) { opened.append(id) }
        }
        return opened
    }
}
