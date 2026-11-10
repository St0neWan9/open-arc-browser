import SwiftUI
import AppKit

// HTML fullscreen (a video's full screen button, `element.requestFullscreen`), plan B212. The
// engine grants it and reports it on the tab; the window then goes full screen with the page alone
// in it (`MainWindowLayout.isPageFullscreen`) and comes back when the page leaves fullscreen.
// inferred: the spec records no page-fullscreen behavior; this is what Chromium-based browsers do.
// A window that was already full screen stays so when the page leaves. Leaving the window's full
// screen (green button, ⌃⌘F) or selecting another tab ends the page's fullscreen.

/// Drives the window's full screen from the selected page's HTML fullscreen.
struct PageFullscreenWindowDriver: NSViewRepresentable {
    /// The selected tab while its page is in HTML fullscreen; nil otherwise.
    let tabID: UUID?
    /// Ends the HTML fullscreen of a tab.
    let exitPage: @MainActor (UUID) -> Void

    func makeNSView(context: Context) -> PageFullscreenWindowView {
        let view = PageFullscreenWindowView()
        view.exitPage = exitPage
        view.apply(tabID: tabID)
        return view
    }

    func updateNSView(_ nsView: PageFullscreenWindowView, context: Context) {
        nsView.exitPage = exitPage
        nsView.apply(tabID: tabID)
    }

    static func dismantleNSView(_ nsView: PageFullscreenWindowView, coordinator: ()) {
        nsView.detach()
    }
}

@MainActor
final class PageFullscreenWindowView: NSView {
    var exitPage: (@MainActor (UUID) -> Void)?
    /// The tab whose page holds HTML fullscreen.
    private(set) var fullscreenTab: UUID?
    /// The window went full screen for the page, so it leaves full screen with it.
    private(set) var enteredForPage = false
    /// A tab whose fullscreen the user ended by leaving the window's full screen: not taken full
    /// screen again until the engine reports it left.
    private var dismissedTab: UUID?
    private var isTransitioning = false
    private weak var observedWindow: NSWindow?
    /// For tests: stands in for the window's full screen state and its toggle.
    var windowIsFullScreenForTesting: (() -> Bool)?
    var toggleWindowForTesting: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== observedWindow else { return }
        detach()
        observedWindow = window
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(fullScreenDidChange(_:)), name: name, object: window)
        }
        syncWindow()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    func apply(tabID: UUID?) {
        if tabID == nil { dismissedTab = nil }
        let wanted = tabID == dismissedTab ? nil : tabID
        if let old = fullscreenTab, old != wanted {
            // Another tab was selected while this one was full screen (when the page itself left,
            // this is a no-op).
            exitPage?(old)
        }
        fullscreenTab = wanted
        syncWindow()
    }

    private var isWindowFullScreen: Bool {
        windowIsFullScreenForTesting?() ?? (window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func toggleWindow() {
        if let toggle = toggleWindowForTesting { toggle() } else { window?.toggleFullScreen(nil) }
    }

    /// Takes the window full screen for the page, or back once the page left.
    func syncWindow() {
        guard !isTransitioning, window != nil || toggleWindowForTesting != nil else { return }
        let isFullScreen = isWindowFullScreen
        if fullscreenTab != nil, !isFullScreen {
            enteredForPage = true
            toggleWindow()
        } else if fullscreenTab == nil, isFullScreen, enteredForPage {
            enteredForPage = false
            toggleWindow()
        } else if !isFullScreen {
            enteredForPage = false
        }
    }

    @objc private func fullScreenDidChange(_ notification: Notification) {
        switch notification.name {
        case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
            isTransitioning = true
        case NSWindow.didExitFullScreenNotification:
            isTransitioning = false
            windowDidExitFullScreen()
        default:
            isTransitioning = false
            syncWindow()
        }
    }

    /// The window left full screen. If the page still holds fullscreen, the user left it (green
    /// button, ⌃⌘F): the page leaves too.
    func windowDidExitFullScreen() {
        if let tab = fullscreenTab {
            fullscreenTab = nil
            dismissedTab = tab
            exitPage?(tab)
        }
        enteredForPage = false
        syncWindow()
    }
}
