import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcPersistence
import OpenArcDesign

// Actions behind the menu bar items of plan B72. Items [01] observed (by menu), keys [02]
// observed. In a split the selected tab is the focused pane, so page items act on that pane.

extension ShellModel {
    private var desktop: any DesktopServices { dependencies.desktop }

    // MARK: Arc menu

    /// Arc ▸ Privacy Policy ([01 §Arc] observed): the policy page in a new tab.
    public func openPrivacyPolicy() { openHelpLink(OpenArcLinks.privacyPolicy, title: "Privacy Policy") }

    // MARK: File

    /// File ▸ Share…: the system share picker with the page's address ([01 §File] observed item).
    public func shareCurrentPage() {
        guard let url = sidebar.selectedURL else { return }
        desktop.share([url])
    }

    // MARK: Edit

    /// Edit ▸ Copy URL as Quote (⌃⇧⌘C): the page's selection as a quote with a link that jumps to
    /// it (`QuoteLink`, format inferred). Reads the selection from the engine first.
    public func copySelectedURLAsQuote() {
        guard let id = selectedTabID, let url = sidebar.linkURL(for: id) else { return }
        let title = sidebar.liveState(for: id)?.title ?? workspace.tabs[id]?.displayTitle ?? ""
        let pasteboard = siteControls.pasteboard
        guard let live = selectedLiveTab else {
            pasteboard.writeText(QuoteLink.text(selection: "", title: title, url: url))
            return
        }
        controller.enqueueTabCommand(live) { tab in
            let selection = await tab.selectedText()
            pasteboard.writeText(QuoteLink.text(selection: selection, title: title, url: url))
        }
    }

    /// Edit ▸ Paste and Match Style (⌥⇧⌘V, the macOS standard key): pastes as plain text into
    /// the page ([01 §Edit] observed item; `EditCommand.pasteAndMatchStyle`).
    public func pasteAndMatchStyle() {
        guard let live = selectedLiveTab else { return }
        controller.enqueueTabCommand(live) { await $0.perform(.pasteAndMatchStyle) }
    }

    /// Edit ▸ Find ▸ Jump to Selection (⌘J, [02 §页面与导航] observed): scrolls the page's
    /// selection, or the current find match, into view (inferred: the macOS meaning of the item).
    public func jumpToSelection() {
        guard let live = selectedLiveTab else { return }
        controller.enqueueTabCommand(live) { tab in
            _ = try? await tab.evaluateJavaScript(Self.jumpToSelectionScript)
        }
    }

    /// Scrolls the selection's first range into the middle of the view. Runs in the page.
    static let jumpToSelectionScript = """
    (() => { const s = window.getSelection(); if (!s || s.rangeCount === 0) return false;
      const n = s.getRangeAt(0).startContainer; const e = n.nodeType === 1 ? n : n.parentElement;
      if (!e) return false; e.scrollIntoView({block: "center", inline: "nearest"}); return true; })()
    """

    // MARK: View

    /// View ▸ Collapse Pinned Tabs / Expand Pinned Tabs ([01 §View] observed item; the title flip
    /// is inferred like Hide / Show Sidebar).
    var collapsePinnedMenuTitle: String { sidebar.isPinnedAreaCollapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs" }

    // MARK: Spaces

    /// The Space rows of the Spaces menu. A regular window lists its dock's Spaces; an incognito
    /// window, whose dock is empty, still lists every Space of the app, greyed with the rest of
    /// the menu. [06 §20.2] observed (F5-4).
    var menuSpaces: [Space] { isIncognito ? controller.menuSpaces : sidebar.dockSpaces }

    /// Spaces ▸ Change Profile ([01 §Spaces], [06 §16.3] observed): the sheet for the current Space.
    public func changeProfileOfCurrentSpace() {
        guard let id = selectedSpaceID else { return }
        profileFlow.beginChangeProfile(spaceID: id)
    }

    // MARK: Tabs

    /// Tabs ▸ Reveal Tab in Sidebar (⌃Space, [02 §标签与侧边栏] observed "Reveal Current Tab"):
    /// shows the sidebar if hidden, opens the folders around the tab and the pinned area, and
    /// scrolls the tab's row into view (inferred).
    public func revealSelectedTabInSidebar() {
        guard let id = selectedTabID else { return }
        library.exit()
        if !isSidebarVisible { toggleSidebar() }
        sidebar.reveal(id)
    }

    // MARK: Window

    /// Window ▸ Stay On Top ([01 §Window] observed item): this window floats above other windows
    /// while on; the item shows a check (inferred: a toggle).
    public func toggleStayOnTop() {
        staysOnTop.toggle()
        applyWindowLevel?(staysOnTop)
    }

    // MARK: Help

    /// Help ▸ Getting Started: our local welcome page in a new tab at the top of Today ([06 §27.5]
    /// observed placement).
    public func openGettingStarted() { openHelpPage(.gettingStarted) }

    /// Help ▸ Essential Keyboard Shortcuts: our local page of the shortcuts ([02 §其他] observed:
    /// the item opens a page).
    public func openKeyboardShortcutsPage() { openHelpPage(.keyboardShortcuts) }

    /// Help ▸ Contact the Team (also the command bar row): a new mail to the team.
    public func contactTheTeam() { desktop.open(OpenArcLinks.contactTheTeam) }

    /// Help ▸ Visit Help Center: the help site in a new tab.
    public func openHelpCenter() { openHelpLink(OpenArcLinks.helpCenter, title: "Help Center") }

    /// The incognito bar's project row (our counterpart of Arc's "The Browser Company" row,
    /// [06 §20.1] observed): the project's public page in a new tab. Plan B133.
    func openProjectPage() { openHelpLink(OpenArcLinks.site, title: AppIdentity.displayName) }

    /// The incognito bar's "Tips for Organizing" row ([06 §20.1] observed): our help page. B133.
    func openOrganizingTips() { openHelpLink(OpenArcLinks.organizingTips, title: "Tips for Organizing") }

    /// Help ▸ Troubleshooting ▸ Reveal Open Arc Data: the app's data folder in Finder.
    public func revealAppData() {
        desktop.reveal(dependencies.persistence?.directory ?? AppDataLocation.directory())
    }

    /// Help ▸ Troubleshooting ▸ Copy Open Arc Info: version, engine and macOS on the pasteboard.
    public func copyAppInfo() {
        desktop.copyText(AppDiagnostics.info(engineVersion: dependencies.engine.engineVersion))
    }

    /// The directory the help pages are written to.
    var helpPagesDirectory: URL { HelpPages.directory(dataDirectory: dependencies.persistence?.directory) }

    private func openHelpPage(_ page: HelpPages.Page) {
        guard let url = try? HelpPages.write(page, into: helpPagesDirectory) else { return }
        openHelpLink(url, title: page.title)
    }

    /// Opens `url` as a new tab at the top of Today and shows it ([06 §27.5] observed for Getting
    /// Started; the same for the other help links, inferred). Without a Space (incognito has
    /// none) the tab opens in the window's own list.
    private func openHelpLink(_ url: URL, title: String) {
        library.exit()
        if isCommandBarPresented { dismissCommandBar() }
        sidebar.newTab(url: url, title: title)
        // From the menu with Settings in front: the window used last comes forward.
        focusWindow?()
    }
}

extension SidebarViewModel {
    /// View ▸ Collapse Pinned Tabs is on for the window's Space.
    var isPinnedAreaCollapsed: Bool {
        selectedSpaceID.map(collapsedPinnedSpaceIDs.contains) ?? false
    }

    /// View ▸ Collapse Pinned Tabs: hides or shows the current Space's pinned rows in this window
    /// (inferred: the spec records the item only). Folders keep their own open state. Selecting a
    /// pinned tab shows the area again (`reveal`).
    public func toggleCollapsePinned() {
        guard let spaceID = selectedSpaceID, !isIncognito else { return }
        if collapsedPinnedSpaceIDs.contains(spaceID) { collapsedPinnedSpaceIDs.remove(spaceID) } else { collapsedPinnedSpaceIDs.insert(spaceID) }
    }

    /// Whether the window's Space has pinned rows to collapse. The menu bar reads it after every
    /// burst of changes, so it comes from the memoized snapshot (kept while the area is
    /// collapsed) instead of a scan of every tab (B103).
    var canCollapsePinned: Bool {
        guard selectedSpaceID != nil, !isIncognito else { return false }
        return snapshot.hasPinnedContent
    }

    /// Reveal Tab in Sidebar: expands the collapsed pinned area and the folders around `id`, then
    /// scrolls the row into the middle of the list (inferred). A favorite is always visible.
    func reveal(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        if case .pinned(let spaceID, var folderID) = tab.location {
            collapsedPinnedSpaceIDs.remove(spaceID)
            var closed: [UUID] = []
            var guardCount = 0
            while let current = folderID, let folder = workspace.folders[current], guardCount < 1_000 {
                if !folder.isExpanded { closed.append(current) }
                folderID = folder.parentFolderID
                guardCount += 1
            }
            if !closed.isEmpty {
                let stamp = controller.now()
                _ = menuMutate { state in try closed.reduce(state) { try TreeOps.setFolderExpanded($0, id: $1, isExpanded: true, now: stamp) } }
            }
        }
        scrollToReveal(id)
    }

    /// Scrolls the list so the row of `id` is centered (no-op without a list on screen).
    private func scrollToReveal(_ id: UUID) {
        let snap = snapshot
        guard let scroller = listScroller, let metrics = scroller.metrics,
              let index = snap.listIndex(ofTab: id) else { return }
        let layout = SidebarLayout()
        let frames = layout.listItemFrames(snap.listKinds)
        guard index < frames.count else { return }
        // Content coordinates: the list content starts `listTopSpacer` above the first row.
        let rowTop = frames[index].minY - layout.firstRowTop + CGFloat(Metrics.Sidebar.listTopSpacer)
        let target = min(max(0, rowTop - (metrics.viewportHeight - frames[index].height) / 2), metrics.maxOffset)
        scroller.scroll(toOffset: target)
    }

    /// Tabs ▸ Reset all tabs in this Space ([01 §Tabs], [02 §Space] observed item, no key):
    /// every pinned tab of the Space goes back to its pinned page and unloads, as "—" does for one
    /// row ([06 §16.1] observed for one row; doing it for every pinned tab is inferred). Today tabs
    /// and favorites are left alone.
    public func resetAllPinnedTabsInSpace() {
        guard let spaceID = selectedSpaceID else { return }
        let ids = workspace.allTabs(inSpace: spaceID).filter {
            if case .pinned = $0.location { return true }
            return false
        }.map(\.id)
        ids.forEach(unloadPinnedTab)
    }

    /// Whether Reset all tabs in this Space has anything to act on. The menu bar reads it on every
    /// window update, so it comes from the memoized snapshot instead of a scan of every tab (B99).
    var canResetPinnedTabs: Bool {
        guard selectedSpaceID != nil, !isIncognito else { return false }
        return snapshot.hasPinnedTabs
    }
}

extension SidebarSnapshot {
    /// Index in `listKinds` of the row that shows `tabID` (its own row or its split-group row).
    func listIndex(ofTab tabID: UUID) -> Int? {
        func shows(_ item: SidebarItemModel) -> Bool {
            switch item.kind {
            case .tab(let t): return t.id == tabID
            case .splitGroup(let g): return g.contains(tabID)
            case .folder: return false
            }
        }
        if let index = pinned.firstIndex(where: shows) { return index }
        guard let index = today.firstIndex(where: shows) else { return nil }
        return pinned.count + (showsDivider ? 1 : 0) + 1 + index
    }
}
