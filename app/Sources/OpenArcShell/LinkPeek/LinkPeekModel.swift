import Foundation
import Combine
import OpenArcModel
import OpenArcEngine

// Peek, the floating preview of a link (plan B49). One per browser window.
//
// Spec: docs/arc-spec/06-flows.md §22 (E2 capture).
//   §22.1 observed: what opens it (see WorkspaceController+LinkPeek.swift).
//   §22.2 observed: the panel over the dimmed page, three round buttons on its right (close,
//         expand to a tab, open in split), a badge on the source favorite, and the URL box shows
//         the Peek page's domain.
//   §22.3 observed: Esc, ✕ or a click on the dimmed page closes it and the source is unchanged;
//         expand makes the page a new tab at the top of the current Space's Today and selects it;
//         split makes a new split row in Today: left a copy of the source page, right the Peek
//         page (focused); the source itself is unchanged.
// Inferred (no spec):
//   - The page is a live engine tab with no model tab until it is expanded or split; expanding
//     keeps that engine tab (history, scroll, form state) instead of loading the URL again.
//   - It uses the source tab's profile and color scheme.
//   - A second preview replaces the first; selecting another tab or Space closes it.
//   - Links clicked inside the Peek page navigate there ([06 §22.5] lists it as not captured);
//     tabs it asks for open in the source's Space like any page-opened tab.

@MainActor
public final class LinkPeekModel: ObservableObject {
    /// What the panel shows.
    public struct Session: Equatable {
        /// The model tab the link was clicked in.
        public let sourceTabID: UUID
        /// The link that opened it.
        public let url: URL
        /// The engine tab; nil while the engine creates it.
        public internal(set) var tab: EngineTabID?
    }

    @Published public private(set) var session: Session?
    /// Live state of the Peek page (URL, title, loading).
    /// Not published: the window reads the URL through the sidebar (`publishToSidebar`).
    private(set) var page = SidebarTabLiveState()
    /// The Peek page's engine tab, once made.
    @Published private(set) var liveTab: (any BrowserTab)?

    private let sidebar: SidebarViewModel
    private var controller: WorkspaceController { sidebar.controller }
    private var eventTask: Task<Void, Never>?
    private var selectionObservation: AnyCancellable?
    private var spaceObservation: AnyCancellable?

    init(sidebar: SidebarViewModel) {
        self.sidebar = sidebar
        // Choosing another tab or Space ends the preview (inferred).
        selectionObservation = sidebar.$selectedTabID.dropFirst().sink { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, id != session.sourceTabID else { return }
                self.close()
            }
        }
        spaceObservation = sidebar.$selectedSpaceID.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    public var isOpen: Bool { session != nil }

    /// The URL the window's address box shows while Peek is open: the Peek page's. [06 §22.2] observed.
    var displayedURL: URL? {
        guard let session else { return nil }
        return page.url ?? session.url
    }

    // MARK: Opening

    /// Opens `url` in Peek over `sourceTabID`'s page. Replaces an open preview (inferred).
    public func open(_ url: URL, from sourceTabID: UUID) {
        if session != nil { close() }
        guard let tab = controller.workspace.tabs[sourceTabID], !tab.meta.isTombstone,
              let profileID = controller.engineProfileID(forTab: tab) ?? sidebar.currentProfileID else { return }
        session = Session(sourceTabID: sourceTabID, url: url, tab: nil)
        page = SidebarTabLiveState()
        page.url = url
        page.title = url.host ?? url.absoluteString
        publishToSidebar()
        let scheme = controller.webColorScheme(forTab: sourceTabID)
        let configuration = TabConfiguration(
            profileID: profileID, initialURL: url, isOffTheRecord: controller.isOffTheRecord, preferredColorScheme: scheme
        )
        let engine = controller.dependencies.engine
        controller.enqueueEngineWork { [weak self] in
            guard let live = try? await engine.makeTab(configuration) else {
                self?.close()
                return
            }
            guard let self, self.session?.sourceTabID == sourceTabID, self.session?.url == url, self.liveTab == nil else {
                await engine.closeTab(live.id)
                return
            }
            await self.attach(live)
        }
    }

    private func attach(_ live: any BrowserTab) async {
        liveTab = live
        session?.tab = live.id
        controller.dialogs.observe(live)
        page = SidebarTabLiveState(snapshot: await live.currentState())
        publishToSidebar()
        let stream = live.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.page.apply(event)
                switch event {
                case .urlChanged: self.publishToSidebar()
                // window.close() in the Peek page closes the preview (inferred).
                case .closeRequested: self.close()
                default: break
                }
            }
        }
    }

    // MARK: Buttons

    /// ✕, Esc or a click on the dimmed page: the preview goes away, the source is unchanged.
    /// [06 §22.3] observed.
    public func close() {
        guard session != nil else { return }
        session = nil
        eventTask?.cancel()
        eventTask = nil
        if let live = liveTab {
            controller.dialogs.stopObserving(live.id)
            let engine = controller.dependencies.engine
            controller.enqueueEngineWork { await engine.closeTab(live.id) }
        }
        liveTab = nil
        page = SidebarTabLiveState()
        publishToSidebar()
    }

    /// ⤢: the Peek page becomes a new tab at the top of the current Space's Today, selected.
    /// [06 §22.3] observed. Returns the new tab's id.
    @discardableResult
    public func expand() -> UUID? {
        openInSpace(nil)
    }

    /// ⌘O, "Open Little Arc or Peek in…" ([02 §tabs] observed): the Peek page leaves Peek like a
    /// Little Arc page leaves its window with ⌘O ([06 §21.7] observed there): it becomes the
    /// selected top Today tab of `spaceID` (nil: the window's current Space, the default target
    /// as in Little Arc), and the window switches to that Space. B82. With the default target the
    /// result equals ⤢ (inferred: the spec shows no Space picker for Peek). Returns the new tab's id.
    @discardableResult
    public func openInSpace(_ target: UUID?) -> UUID? {
        guard let session else { return nil }
        let liveTarget = target.flatMap { controller.workspace.spaces[$0]?.meta.isTombstone == false ? $0 : nil }
        guard let spaceID = liveTarget ?? sidebar.selectedSpaceID else { return nil }
        let url = page.url ?? session.url
        let id = controller.makeID()
        let stamp = controller.now()
        let title = pageTitle(for: url)
        let live = handOver()
        do {
            try controller.mutate(origin: nil) { try TreeOps.openTab($0, id: id, spaceID: spaceID, url: url, title: title, now: stamp) }
        } catch {
            if let live { discard(live) }
            return nil
        }
        adopt(live, as: id)
        // The session ended above, so switching Spaces does not close anything any more.
        if sidebar.selectedSpaceID != spaceID { sidebar.selectSpace(spaceID) }
        sidebar.selectTab(id)
        return id
    }

    /// ▯▯: a new split row at the top of Today, the source page's copy on the left and the Peek
    /// page on the right, focused; the source is unchanged. [06 §22.3] observed. Returns the ids
    /// of the copy and of the Peek tab.
    @discardableResult
    public func openInSplit() -> (copy: UUID, peek: UUID)? {
        guard let session, let spaceID = sidebar.selectedSpaceID,
              let source = controller.workspace.tabs[session.sourceTabID] else { return nil }
        let url = page.url ?? session.url
        let sourceURL = controller.liveState(for: source.id)?.url ?? source.url ?? source.pinnedURL
        let sourceTitle = controller.liveState(for: source.id)?.title.nonEmpty ?? source.displayTitle
        let copyID = controller.makeID(), peekID = controller.makeID(), layoutID = controller.makeID()
        let stamp = controller.now()
        let title = pageTitle(for: url)
        let live = handOver()
        do {
            try controller.mutate(origin: nil) { state in
                var s = try TreeOps.openTab(state, id: copyID, spaceID: spaceID, url: sourceURL, title: sourceTitle, now: stamp)
                s = try TreeOps.openTab(s, id: peekID, spaceID: spaceID, url: url, title: title, now: stamp)
                s = try TreeOps.moveTab(s, id: peekID, to: .today(spaceID: spaceID), position: .after(copyID), now: stamp)
                return try TreeOps.addSplitPane(s, layoutID: layoutID, existingTabID: copyID, newTabID: peekID, now: stamp)
            }
        } catch {
            if let live { discard(live) }
            return nil
        }
        adopt(live, as: peekID)
        sidebar.selectTab(peekID)
        let sidebar = self.sidebar
        controller.enqueueEngineWork { await sidebar.ensureLive(copyID) }
        return (copyID, peekID)
    }

    // MARK: Helpers

    private func pageTitle(for url: URL) -> String {
        page.title.nonEmpty ?? url.host ?? url.absoluteString
    }

    /// Ends the session but keeps the engine tab for a model tab. nil while the engine has not
    /// made it yet: the model tab then loads its URL the usual way.
    private func handOver() -> (any BrowserTab)? {
        let live = liveTab
        eventTask?.cancel()
        eventTask = nil
        liveTab = nil
        session = nil
        page = SidebarTabLiveState()
        publishToSidebar()
        return live
    }

    /// Registers the Peek page's engine tab as model tab `id`'s, so it is not loaded again.
    private func adopt(_ live: (any BrowserTab)?, as id: UUID) {
        guard let live else { return }
        let controller = self.controller
        controller.pageRequests.adopting.insert(id)
        controller.enqueueEngineWork {
            await controller.attachLive(id, live)
            controller.pageRequests.adopting.remove(id)
        }
    }

    private func discard(_ live: any BrowserTab) {
        controller.dialogs.stopObserving(live.id)
        let engine = controller.dependencies.engine
        controller.enqueueEngineWork { await engine.closeTab(live.id) }
    }

    /// The address box and the source favorite's badge read these. [06 §22.2] observed.
    private func publishToSidebar() {
        sidebar.linkPeekURL = displayedURL
        sidebar.linkPeekSourceTabID = session?.sourceTabID
    }

    func stop() {
        selectionObservation = nil
        spaceObservation = nil
        close()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
