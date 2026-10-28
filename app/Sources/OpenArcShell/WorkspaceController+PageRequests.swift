import Foundation
import OpenArcModel
import OpenArcEngine

// Tabs and closes the page asks for (plan C7b; chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §1, §2).
//
// Spec: [06 §13] observed that a new tab goes to the TOP of Today; [06 §4] observed that a
// Shift-click opened a new window whose tab sat in Today. Everything else here is inferred (the
// spec records no page-opened tabs or page-initiated closes):
// - Foreground and background tabs open in the opener's Space, in Today. An opener in Today gets
//   its child right below it, and later children of the same opener below the previous one
//   (Chrome-like). An opener that is pinned or a favorite puts its first child at the top of
//   Today ([06 §13]) and later ones below it.
// - Foreground tabs are selected in the window that shows the opener; background tabs load
//   without being selected.
// - A popup (window.open with window features) opens like a foreground tab. We chose a Today tab
//   over a Little Arc window so the popup keeps the opener's Space, is reachable from the sidebar
//   and goes through TreeOps like every tab; when it closes itself the opener is selected again.
// - A new-window request opens a new browser window on the opener's Space showing the new tab.
// - `window.close()` archives a Today tab (reason `.closed`, so ⇧⌘T can bring it back) and
//   unloads a pinned tab or favorite (its pin stays, like the "—" button). If the closed tab was
//   on screen and a page opened it, its opener is selected again.
// - Requests from a tab this controller does not own are left to the controller that owns it;
//   requests without an opener (extensions, notifications) go to the app's controller. A pending
//   tab nobody adopts is declined by the engine when its opener closes.

/// Bookkeeping for page-initiated tabs. One per `WorkspaceController`.
@MainActor
final class PageRequestState {
    /// Model tabs whose engine tab is being adopted: `ensureLive` must not make a second one.
    var adopting: Set<UUID> = []
    /// Opener engine tab of model tabs opened by URL; `ensureLive` passes it to `makeTab`.
    var openers: [UUID: EngineTabID] = [:]
    /// Opener model tab of every page-opened tab (to select it again when the child closes).
    var openerOf: [UUID: UUID] = [:]
    /// The child a page opened last, per opener model tab (the next child goes below it).
    var lastChild: [UUID: UUID] = [:]
    var task: Task<Void, Never>?
    /// Popups of extension `_execute_action` shortcuts (plan C26).
    var keyboardPopupTask: Task<Void, Never>?
    private(set) var isStopped = false

    func stop() {
        isStopped = true
        task?.cancel()
        task = nil
        keyboardPopupTask?.cancel()
        keyboardPopupTask = nil
    }
}

extension WorkspaceController {
    /// Starts handling `EngineEvent.newTabRequested`. Called once by each init.
    func observeEngineEvents() {
        observeKeyboardExtensionPopups()
        let stream = dependencies.engine.events()
        pageRequests.task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                // A Peek page has no model tab: its source tab stands in (B49).
                if case .newTabRequested(let request) = event, !self.handleLinkPeekNewTabRequest(request) {
                    self.handleNewTabRequest(request)
                }
            }
        }
    }

    /// Shows the popups extension `_execute_action` shortcuts open (plan C26) in the window that
    /// shows their tab, as after a click on the action. [00 §A] inferred (analysis): extension
    /// keyboard commands work. The controller that owns the tab answers; when no window shows it,
    /// the popup is closed.
    private func observeKeyboardExtensionPopups() {
        let stream = dependencies.engine.extensions.popupsOpenedFromKeyboard()
        pageRequests.keyboardPopupTask = Task { [weak self] in
            for await opened in stream {
                guard let self else { return }
                let popup = opened.popup
                guard let tabID = self.modelTabID(forEngineTab: popup.tabID) else { continue }
                let shown = self.browserWindows.contains { $0.siteControls.showPopupFromKeyboard(popup, tabID: tabID) }
                if !shown { Task { await popup.close() } }
            }
        }
    }

    /// Places a tab the page asked for. See the file header for the rules.
    func handleNewTabRequest(_ request: NewTabRequest) {
        guard !pageRequests.isStopped else { return }
        var request = request
        let openerTabID = request.opener.flatMap(modelTabID(forEngineTab:))
        // ⌥⌘-click in a Little Arc page: another Little Arc (B82). Its engine tab has no model tab.
        if request.disposition == .littleArc, openerTabID == nil, let opener = request.opener,
           littleArcArchive.openModels.contains(where: { $0.liveTab?.id == opener }) {
            if !openLinkClickInLittleArc(request) { decline(request) }
            return
        }
        // Not ours: an opener another controller (or a Little Arc window) owns, or an
        // opener-less request while this is an incognito controller.
        if request.opener != nil, openerTabID == nil { return }
        if request.opener == nil, isOffTheRecord { return }
        // ⌥⌘-click a link (B82): a Little Arc window when the setting is on, else what ⌘-click does.
        if request.disposition == .littleArc {
            if openLinkClickInLittleArc(request) { return }
            request.disposition = .backgroundTab
        }

        let window = openerTabID.flatMap(windowShowing) ?? activeWindowSidebar
        guard let spaceID = openerTabID.flatMap(spaceOfOpener) ?? window?.selectedSpaceID ?? activeSpaceID else {
            decline(request)
            return
        }
        let id = makeID()
        let title = request.url.host ?? request.url.absoluteString
        let position = openerTabID.map { childPosition(opener: $0, spaceID: spaceID) } ?? .first
        let stamp = now()
        do {
            try mutate(origin: nil) { ws in
                var s = try TreeOps.openTab(ws, id: id, spaceID: spaceID, url: request.url, title: title, now: stamp)
                if position != .first {
                    s = try TreeOps.moveTab(s, id: id, to: .today(spaceID: spaceID), position: position, now: stamp)
                }
                return s
            }
        } catch {
            decline(request)
            return
        }
        if let openerTabID {
            pageRequests.openerOf[id] = openerTabID
            pageRequests.lastChild[openerTabID] = id
        }

        // The engine tab: adopt the one the engine made, or make one by URL.
        if let token = request.pendingTab {
            adopt(token, as: id)
        } else if let opener = request.opener {
            pageRequests.openers[id] = opener
        }

        switch request.disposition {
        case .foregroundTab, .popup:
            if let window {
                if window.selectedSpaceID != spaceID { window.selectSpace(spaceID) }
                window.selectTab(id, focusingOtherWindow: false)
            } else {
                loadInBackground(id)
            }
        case .backgroundTab, .littleArc:
            loadInBackground(id)
        case .newWindow:
            loadInBackground(id)
            if let open = openBrowserWindow {
                open(BrowserWindowRequest(kind: .newWindow, spaceID: spaceID, tabID: id))
            }
        }
    }

    /// The page asked to close itself (`TabEvent.closeRequested`). See the file header.
    func pageRequestedClose(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        let opener = pageRequests.openerOf.removeValue(forKey: id)
        let windows = liveSidebars.filter { $0.selectedTabID == id }
        let isToday: Bool
        if case .today = tab.location { isToday = true } else { isToday = false }

        if let first = windows.first {
            // The window repairs its own selection (neighbor row, like ⌘W).
            if isToday { first.closeTab(id) } else { first.unloadPinnedTab(id) }
        } else if isToday {
            let stamp = now()
            try? mutate(origin: nil) { try TreeOps.archiveTab($0, id: id, reason: .closed, now: stamp) }
            closeLive(id)
        } else {
            closeLive(id)
        }
        // Back to the page that opened it.
        if let opener, workspace.tabs[opener].map({ !$0.meta.isTombstone }) == true {
            for window in windows { window.selectTab(opener, focusingOtherWindow: false) }
        }
    }

    /// The page asked to be shown (`TabEvent.activationRequested`: `window.focus()`, or "back to
    /// tab" in its Picture in Picture window). The window that shows the tab, else the active
    /// window, selects it and comes to the front. inferred (the spec records neither).
    func pageRequestedActivation(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        if let window = browserWindows.first(where: { $0.selectedTabID == id }) ?? activeWindow {
            window.revealTab(id)
        }
    }

    // MARK: - Helpers

    /// Adopts a pending engine tab as the engine tab of model tab `id`.
    private func adopt(_ token: PendingTabToken, as id: UUID) {
        pageRequests.adopting.insert(id)
        let engine = dependencies.engine
        enqueueEngineWork { [weak self] in
            do {
                let live = try await engine.adoptTab(token, requestedID: nil)
                guard let self else {
                    await engine.closeTab(live.id)
                    return
                }
                self.pageRequests.adopting.remove(id)
                await self.attachLive(id, live)
            } catch {
                // Gone (opener closed, already answered): the tab keeps its URL and loads it the
                // usual way when shown.
                self?.pageRequests.adopting.remove(id)
            }
        }
    }

    /// "Open Little Arc when you ⌥⌘-click a link" (B82, [03 §Links] observed switch): the link
    /// opens in a new Little Arc window, already expanded on the page (like a link from another
    /// app, B24). Returns false when the switch is off, the controller is incognito (a Little Arc
    /// window is never off the record, inferred), the URL is not a web link or no window opener
    /// is installed; the caller then treats the click as a ⌘-click.
    func openLinkClickInLittleArc(_ request: NewTabRequest) -> Bool {
        guard dependencies.preferences.opensLittleArcOnOptionCommandClick, !isOffTheRecord,
              ExternalOpen.isWebLink(request.url), let open = openLittleArcWindow else { return false }
        // The engine made no tab worth keeping: the Little Arc page loads the URL itself.
        decline(request)
        let id = issueLittleArcWindowID()
        littleArcLaunchURLs[id] = request.url
        open(id)
        return true
    }

    private func decline(_ request: NewTabRequest) {
        guard let token = request.pendingTab else { return }
        let engine = dependencies.engine
        enqueueEngineWork { await engine.declineTab(token) }
    }

    /// Makes the engine tab of an unselected page-opened tab (background tabs load right away).
    private func loadInBackground(_ id: UUID) {
        guard !pageRequests.adopting.contains(id) else { return }
        let fallback = currentProfileID
        enqueueEngineWork { [weak self] in
            try? await self?.ensureLive(id, fallbackProfileID: fallback)
        }
    }

    /// Where the next child of `opener` goes in Today. See the file header.
    private func childPosition(opener: UUID, spaceID: UUID) -> InsertPosition {
        let today = Set(workspace.today(spaceID: spaceID).map(\.id))
        if let last = pageRequests.lastChild[opener], today.contains(last) { return .after(last) }
        if today.contains(opener) { return .after(opener) }
        return .first
    }

    /// The Space a child of `opener` opens in: the opener's, or for a favorite the Space of the
    /// window that shows it.
    private func spaceOfOpener(_ opener: UUID) -> UUID? {
        guard let tab = workspace.tabs[opener] else { return nil }
        return tab.location.spaceID ?? windowShowing(opener)?.selectedSpaceID
    }

    /// The window that has `tabID` on screen.
    private func windowShowing(_ tabID: UUID) -> SidebarViewModel? {
        liveSidebars.first { $0.countsAsVisibleWindow && $0.onScreenTabIDs.contains(tabID) }
    }

    /// The window used last, else any open one.
    private var activeWindowSidebar: SidebarViewModel? {
        activeWindow?.sidebar ?? liveSidebars.first { $0.countsAsVisibleWindow }
    }
}
