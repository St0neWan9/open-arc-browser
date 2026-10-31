import SwiftUI
import AppKit
import Combine
import QuartzCore
import OpenArcDesign

// The sidebar's Space pages (plan B101). [05 §window hierarchy] observed: the Spaces are a row of
// horizontal pages; [07 §11] observed: a switch moves the page container by one sidebar width
// (276 pt) on a critically damped spring (response 0.2 s), no fade.
//
// Each Space page (its name row and its tab list) lives in its own `NSHostingView`, kept after
// it was shown: switching back to a recent Space only moves an existing page, and the slide runs
// as a Core Animation spring on the pages' layers, so SwiftUI does no work per frame. (B99
// measured 35–43 ms per switch whatever the Space size when SwiftUI rebuilt the page and
// interpolated its offset every frame.) Pages that are not on screen stay in the view tree, hidden:
// taking a hosting view out of the window and putting it back cost ≈ 8 ms per switch (AppKit
// moves the whole subtree between windows and SwiftUI rebuilds its removed state, B104 profile).
// A hidden page is not updated for each change while away (`SidebarSpacePageChanges`). B106: so
// that the first frame of its slide draws its current content, a hidden page whose rows or header
// would now draw differently is updated and laid out while still hidden, once the sidebar has
// been quiet for a moment (`hiddenPagePrepareDelay`), outside the switch; a change that comes too
// close to the switch is caught up when the switch is announced, before the page is shown. A page
// that would draw the same (most changes belong to other Spaces) costs only that comparison.

/// Tells one kept Space page that an object it draws from (the sidebar view model, or the list
/// scroll state) changed. The page's views observe this instead of that object, so a page that is
/// hidden does no work for the changes made while it is away. B104, B106.
@MainActor
final class SidebarSpacePageChanges: ObservableObject {
    /// Whether the page is on screen. A page that is still stale when shown (nothing it draws
    /// changed, or the switch's own changes came after it was brought up to date) catches up in
    /// the run loop pass after the one that showed it: showing happens inside a view update, where
    /// publishing is not allowed. B106: changes that alter what it draws are caught up before.
    var isShown = true {
        didSet {
            guard isShown, !oldValue, isStale else { return }
            scheduleCatchUp()
        }
    }
    /// A change came while the page was hidden and the page has not caught up yet.
    private(set) var isStale = false
    /// How often the page was told to update. For tests.
    private(set) var publishCount = 0
    /// How often the page caught up before being shown (`catchUpBeforeShowing`). For tests.
    private(set) var catchUpsBeforeShowing = 0
    private var isCatchUpScheduled = false
    /// What the page's list rows and header last drew, recorded by those views' bodies (B106).
    /// Plain records, never published.
    private(set) var drawnRows: SidebarListRowsLook?
    private(set) var drawnHeader: SidebarSpaceHeaderLook?

    /// The relayed object is about to change.
    func sourceWillChange() {
        guard isShown else {
            isStale = true
            return
        }
        isStale = false
        publish()
    }

    /// Updates a hidden page that missed changes, for a caller that lays it out right away, before
    /// it is shown (B106). Returns whether the page was told to update. Called outside any view
    /// update (the Space switch's announcement), where publishing is allowed.
    func catchUpBeforeShowing() -> Bool {
        guard isStale else { return false }
        isStale = false
        catchUpsBeforeShowing += 1
        publish()
        return true
    }

    /// Records what the page's list rows drew (`drawnRows`).
    func noteDrawn(rows: SidebarListRowsLook) { drawnRows = rows }
    /// Records what the page's header drew (`drawnHeader`).
    func noteDrawn(header: SidebarSpaceHeaderLook) { drawnHeader = header }

    /// Whether the page's rows and header would draw differently now in `viewModel` (B106). Only
    /// the rows the list has built (its band) are compared: the others are built when scrolled to.
    func drawsDifferently(spaceID: UUID?, in viewModel: SidebarViewModel) -> Bool {
        guard let drawnRows, let drawnHeader else { return true }
        if viewModel.spaceHeaderLook(for: spaceID) != drawnHeader { return true }
        let now = viewModel.listRowsLook(content: viewModel.listContent(for: spaceID), spaceID: spaceID,
                                         minY: drawnRows.minY, maxY: drawnRows.maxY)
        return !now.drawsSame(as: drawnRows)
    }

    /// Updates a shown page that missed changes. Runs after the showing pass has drawn; tests call
    /// it to skip the wait. A Space switch brings the page up to date before showing it
    /// (`catchUpBeforeShowing`), so this is left for changes that come after that.
    func catchUp() {
        isCatchUpScheduled = false
        guard isShown, isStale else { return }
        isStale = false
        publish()
    }

    private func scheduleCatchUp() {
        guard !isCatchUpScheduled else { return }
        isCatchUpScheduled = true
        Task { [weak self] in
            await MainRunLoopTurn.next()
            self?.catchUp()
        }
    }

    private func publish() {
        publishCount += 1
        objectWillChange.send()
    }
}

/// One Space page: the Space name row and the tab list, drawn in the sidebar's root coordinates
/// (the page's host is as large as the sidebar and the pager clips it to the page band).
struct SidebarSpacePage: View {
    /// Read, not observed: `changes` says when the page must update (B104).
    let viewModel: SidebarViewModel
    @ObservedObject var changes: SidebarSpacePageChanges
    /// `scroll`'s changes, relayed while the page is shown (only the list decorations follow them).
    let scrollChanges: SidebarSpacePageChanges
    let spaceID: UUID?
    let scroll: SidebarListScrollState
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    let surface: WindowSurface

    var body: some View {
        let listHeight = max(0, layout.listBottom - layout.listTop)
        ZStack(alignment: .topLeading) {
            SidebarSpaceNameRowView(viewModel: viewModel, changes: changes, spaceID: spaceID, layout: layout)

            SidebarListView(viewModel: viewModel, changes: changes, scrollChanges: scrollChanges, content: viewModel.listContent(for: spaceID), spaceID: spaceID,
                            scroll: scroll, isSidebarHovered: isSidebarHovered, layout: layout)
                .frame(width: layout.width, height: listHeight)
                .offset(y: layout.listTop)
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
        // Frames reported from inside the page (drop regions, speaker glyphs) are in the sidebar's
        // root space: the page's host has the sidebar's origin.
        .coordinateSpace(name: SidebarCoordinateSpace.root)
        .environment(\.windowSurface, surface)
        .environment(\.sidebarAudioGlyphSink, scroll)
        .onPreferenceChange(SidebarDropRegionsKey.self) { [scroll] regions in
            // Every page has the same list and Space-name frames.
            MainActor.assumeIsolated { scroll.setPageRegions(regions) }
        }
        .ignoresSafeArea()
    }
}

/// The pages of the sidebar's Spaces, placed over the page band (Space name row to dock).
struct SidebarSpacePager: NSViewRepresentable {
    /// Pages kept: the shown Space and the ones shown last. Own value: a few, so a back-and-forth
    /// between recent Spaces never rebuilds a page.
    static let maxPages = 5
    /// How long the sidebar must be quiet before hidden pages whose Space changed are brought up
    /// to date (B106). Own value: long enough that a burst of changes (a page loading in the shown
    /// Space) costs one check per hidden page, not one per change; short next to the time a person
    /// takes to switch back to a Space after something changed in it.
    static let hiddenPagePrepareDelay: Duration = .milliseconds(150)

    /// Not observed: the pages follow the view model through `SidebarSpacePageChanges`, and the
    /// pager itself only needs the inputs below (B104).
    let viewModel: SidebarViewModel
    /// Read here so a switch reaches `updateNSView`.
    let selectedSpaceID: UUID?
    let scroll: SidebarListScrollState
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    let surface: WindowSurface

    /// Top of the page band in the sidebar: the Space header. [07 §4] observed (y 145).
    static func bandTop(_ layout: SidebarLayout) -> CGFloat {
        CGFloat(Metrics.Sidebar.spaceHeaderTop) - layout.contentShift
    }

    func makeNSView(context: Context) -> SidebarSpacePagerView {
        let view = SidebarSpacePagerView()
        view.update(inputs, selectedSpaceID: selectedSpaceID)
        return view
    }

    func updateNSView(_ nsView: SidebarSpacePagerView, context: Context) {
        nsView.update(inputs, selectedSpaceID: selectedSpaceID)
    }

    /// The pager takes the size it is given. Without this SwiftUI asks AppKit for the view's
    /// fitting size, which walks the constraints of every kept page on each update (B101 profile).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarSpacePagerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? layout.width, height: proposal.height ?? 0)
    }

    private var inputs: SidebarSpacePagerView.Inputs {
        .init(viewModel: viewModel, scroll: scroll, isSidebarHovered: isSidebarHovered, layout: layout, surface: surface)
    }
}

/// The AppKit side of `SidebarSpacePager`: one hosting view per kept Space page, clipped to the
/// page band, slid by layer animations.
@MainActor
final class SidebarSpacePagerView: NSView {
    struct Inputs {
        let viewModel: SidebarViewModel
        let scroll: SidebarListScrollState
        let isSidebarHovered: Bool
        let layout: SidebarLayout
        let surface: WindowSurface

        /// Whether a page drawn with `self` would draw differently with `other`.
        func drawsSame(as other: Inputs) -> Bool {
            viewModel === other.viewModel && scroll === other.scroll && isSidebarHovered == other.isSidebarHovered
                && layout == other.layout && surface == other.surface
        }
    }

    typealias PageHost = NSHostingView<SidebarSpacePage>

    @MainActor
    private final class Page {
        let host: PageHost
        /// Tell the page's views when the sidebar or its scroll state changed, while the page is shown.
        let changes: SidebarSpacePageChanges
        let scrollChanges: SidebarSpacePageChanges
        /// The inputs the host's root view was last given.
        var inputs: Inputs
        init(host: PageHost, changes: SidebarSpacePageChanges, scrollChanges: SidebarSpacePageChanges, inputs: Inputs) {
            self.host = host
            self.changes = changes
            self.scrollChanges = scrollChanges
            self.inputs = inputs
        }
        func setShown(_ shown: Bool) {
            changes.isShown = shown
            scrollChanges.isShown = shown
        }
        /// On screen: in the pager and not hidden.
        var isShown: Bool { !host.isHidden && host.superview != nil }
    }

    private var inputs: Inputs?
    /// Kept pages by Space, and the Spaces in the order they were shown (most recent last).
    private var pages: [UUID?: Page] = [:]
    private var recent: [UUID?] = []
    /// The Space whose page is shown (or sliding in).
    private(set) var shownSpaceID: UUID??
    /// Forward the view model's and the scroll state's changes to the pages (`SidebarSpacePageChanges`).
    private var modelChanges: AnyCancellable?
    private var spaceWillChange: AnyCancellable?
    private var scrollStateChanges: AnyCancellable?
    private weak var observedModel: SidebarViewModel?
    private weak var observedScroll: SidebarListScrollState?
    /// Bumped by every slide, so the completion of an overtaken slide does nothing.
    private var slideGeneration = 0
    /// The pages taking part in the running slide (the incoming one and the outgoing ones).
    private var slidingSpaceIDs: Set<UUID?> = []
    /// When the view model last changed, and whether a pass to prepare hidden pages is waiting
    /// for the sidebar to be quiet (`prepareHiddenPagesWhenQuiet`).
    private var lastModelChange: ContinuousClock.Instant = .now
    private var isPrepareScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The outgoing page must not draw over the web panel or the blocks above and below.
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// For tests: the Spaces with a kept page, and those whose page is in the view tree.
    var keptSpaceIDs: [UUID?] { recent }
    var attachedSpaceIDs: [UUID?] { recent.filter { pages[$0]?.isShown == true } }
    /// For tests: the hosting view of `spaceID`'s kept page.
    func pageHost(for spaceID: UUID?) -> NSView? { pages[spaceID]?.host }
    /// For tests: the change relay of `spaceID`'s kept page.
    func pageChanges(for spaceID: UUID?) -> SidebarSpacePageChanges? { pages[spaceID]?.changes }
    /// For tests: what happens when the running slide's spring has settled.
    func finishSlideForTesting() { slideEnded(generation: slideGeneration) }
    /// For tests: called with a page's Space right before a hidden page is shown again.
    var pageWillShowForTesting: ((UUID?) -> Void)?
    /// How many hidden pages were updated and laid out at the switch (`bringUpToDate`) and while
    /// away (`prepareHiddenPages`). For tests and the self test.
    private(set) var pagesBroughtUpToDate = 0
    private(set) var pagesPreparedWhileHidden = 0
    /// For tests: brings every hidden page whose Space changed up to date now, without waiting.
    func prepareHiddenPagesForTesting() { prepareHiddenPages(all: true) }

    override func layout() {
        super.layout()
        guard let inputs else { return }
        let frame = pageFrame(inputs.layout)
        for page in pages.values where page.host.frame != frame { page.host.frame = frame }
    }

    /// A page's host frame: the whole sidebar, shifted so its content lands in root coordinates.
    private func pageFrame(_ layout: SidebarLayout) -> CGRect {
        CGRect(x: 0, y: -SidebarSpacePager.bandTop(layout), width: layout.width, height: layout.windowSize.height)
    }

    func update(_ new: Inputs, selectedSpaceID: UUID?) {
        let changed = inputs.map { !$0.drawsSame(as: new) } ?? true
        inputs = new
        observe(new.viewModel, new.scroll)
        if changed {
            for page in pages.values where page.isShown { refresh(page) }
            needsLayout = true
        }
        guard shownSpaceID != .some(selectedSpaceID) else { return }
        show(selectedSpaceID, animated: shownSpaceID != nil)
    }

    /// Forwards the changes of `viewModel` and `scroll` to the pages; each page passes them on
    /// only while it is shown.
    private func observe(_ viewModel: SidebarViewModel, _ scroll: SidebarListScrollState) {
        if observedModel !== viewModel {
            observedModel = viewModel
            // The page on screen leaves on a switch: it stops following the sidebar before the
            // switch is published, so the switch does not update it while it slides out. The
            // page coming back is brought up to date at the same moment (B106).
            spaceWillChange = viewModel.selectedSpaceWillChange.sink { [weak self] next in
                MainActor.assumeIsolated { self?.spaceWillChange(to: next) }
            }
            modelChanges = viewModel.objectWillChange.sink { [weak self] _ in
                // Both objects are main-actor isolated and publish on the main thread.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for page in self.pages.values { page.changes.sourceWillChange() }
                    self.lastModelChange = .now
                    self.prepareHiddenPagesWhenQuiet()
                }
            }
        }
        if observedScroll !== scroll {
            observedScroll = scroll
            scrollStateChanges = scroll.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for page in self.pages.values { page.scrollChanges.sourceWillChange() }
                }
            }
        }
    }

    /// The sidebar is about to show `next`: the pages of the other Spaces stop following it, and
    /// `next`'s kept page catches up on what it missed while hidden, if that was not done already
    /// while the sidebar was quiet.
    private func spaceWillChange(to next: UUID?) {
        for (id, page) in pages where id != next { page.setShown(false) }
        // The switch's own changes that follow (the selected Space, its remembered tab selected
        // again) do not change what the incoming page draws (`pageSelectedTabID`): they mark it
        // stale and it catches up after it is shown, as in B104, so a switch to a page that missed
        // nothing pays for no update before its first frame.
        if let page = pages[next], bringUpToDate(page, spaceID: next) { pagesBroughtUpToDate += 1 }
    }

    /// Updates and lays out a kept page whose rows or header changed while it was hidden, before it
    /// is shown: the first frame of its slide draws its current titles, rows and Space name
    /// instead of the ones it had when it left (B106). Called while the page is hidden: when the
    /// sidebar is quiet (`prepareHiddenPages`) and, for a change too close to the switch, when the
    /// switch is announced (outside any view update: publishing is not allowed inside one, which is
    /// why `attach` cannot do it). Only a page that would draw differently pays for the update; a
    /// page that would draw the same stays stale and catches up after it is shown, as in B104. The
    /// scroll relay is not caught up here: the hidden list's scroll decorations follow its own
    /// offset, which does not change while it is away. Returns whether the page was updated.
    @discardableResult
    private func bringUpToDate(_ page: Page, spaceID: UUID?) -> Bool {
        guard page.changes.isStale, let inputs,
              page.changes.drawsDifferently(spaceID: spaceID, in: inputs.viewModel),
              page.changes.catchUpBeforeShowing() else { return false }
        // One SwiftUI update and layout of this page only, at the size it will be shown at.
        if page.host.frame != pageFrame(inputs.layout) { page.host.frame = pageFrame(inputs.layout) }
        page.host.layoutSubtreeIfNeeded()
        return true
    }

    /// Once the sidebar has been quiet for `hiddenPagePrepareDelay`, brings the hidden pages whose
    /// Space changed up to date, so switching back to them does not pay for it (B106).
    private func prepareHiddenPagesWhenQuiet() {
        guard !isPrepareScheduled, !waitingHiddenPages.isEmpty else { return }
        isPrepareScheduled = true
        Task { [weak self] in
            // Waits until no change came for the whole delay; holds no reference while asleep.
            while let quietUntil = self.map({ $0.lastModelChange + SidebarSpacePager.hiddenPagePrepareDelay }),
                  ContinuousClock.now < quietUntil {
                try? await Task.sleep(until: quietUntil, clock: .continuous)
            }
            guard let self else { return }
            self.isPrepareScheduled = false
            self.prepareHiddenPages(all: false)
        }
    }

    /// Updates and lays out hidden pages that would draw differently now, while they stay hidden.
    /// One page per run loop pass (most recently shown first), so no pass does more than one
    /// page's work; a change in between postpones the rest to the next quiet moment.
    private func prepareHiddenPages(all: Bool) {
        prepare(waitingHiddenPages[...], all: all, generation: lastModelChange)
    }

    /// Hidden pages that missed changes, most recently shown first. A page still sliding out is
    /// left alone (B104: the slide must not update it); `slideEnded` looks again.
    private var waitingHiddenPages: [UUID?] {
        recent.reversed().filter { id in
            guard let page = pages[id], page.host.isHidden, !slidingSpaceIDs.contains(id) else { return false }
            return page.changes.isStale
        }
    }

    private func prepare(_ queue: ArraySlice<UUID?>, all: Bool, generation: ContinuousClock.Instant) {
        guard let next = queue.first else { return }
        if let page = pages[next], page.host.isHidden, bringUpToDate(page, spaceID: next) { pagesPreparedWhileHidden += 1 }
        let rest = queue.dropFirst()
        guard !rest.isEmpty else { return }
        if all { return prepare(rest, all: true, generation: generation) }
        Task { [weak self] in
            await MainRunLoopTurn.next()
            guard let self, self.lastModelChange == generation else { return }
            self.prepare(rest, all: false, generation: generation)
        }
    }

    private func refresh(_ page: Page) {
        guard let inputs, !page.inputs.drawsSame(as: inputs) else { return }
        page.inputs = inputs
        page.host.rootView = rootView(for: page.host.rootView.spaceID, changes: page.changes,
                                      scrollChanges: page.scrollChanges, inputs: inputs)
    }

    private func rootView(for spaceID: UUID?, changes: SidebarSpacePageChanges, scrollChanges: SidebarSpacePageChanges,
                          inputs: Inputs) -> SidebarSpacePage {
        SidebarSpacePage(viewModel: inputs.viewModel, changes: changes, scrollChanges: scrollChanges,
                         spaceID: spaceID, scroll: inputs.scroll,
                         isSidebarHovered: inputs.isSidebarHovered, layout: inputs.layout, surface: inputs.surface)
    }

    /// The kept page of `spaceID`, made when there is none.
    private func page(for spaceID: UUID?) -> Page {
        if let page = pages[spaceID] { return page }
        guard let inputs else { preconditionFailure("the pager has no inputs yet") }
        let changes = SidebarSpacePageChanges(), scrollChanges = SidebarSpacePageChanges()
        let host = PageHost(rootView: rootView(for: spaceID, changes: changes, scrollChanges: scrollChanges, inputs: inputs))
        // The page has a given frame: no fitting-size or intrinsic-size measuring of its content.
        host.sizingOptions = []
        host.frame = pageFrame(inputs.layout)
        let page = Page(host: host, changes: changes, scrollChanges: scrollChanges, inputs: inputs)
        pages[spaceID] = page
        return page
    }

    /// Shows `spaceID`'s page: slides it in and the shown one out ([07 §11]), or puts it in place.
    private func show(_ spaceID: UUID?, animated: Bool) {
        guard let inputs else { return }
        let previous = shownSpaceID
        shownSpaceID = .some(spaceID)
        recent.removeAll { $0 == spaceID }
        recent.append(spaceID)
        let incoming = page(for: spaceID)
        // A page already moving (a switch during a slide, e.g. straight back) starts from where it
        // is drawn now: read before `attach` stops its animation.
        let incomingPresented = presentedOffset(incoming.host)
        attach(incoming)
        // The list on screen is the one drag auto-scroll and the jump button move.
        if let hook = inputs.scroll.scrollHook(for: spaceID) { inputs.viewModel.listScroller = hook }

        slideGeneration &+= 1
        let generation = slideGeneration
        let pager = inputs.viewModel.spacePager
        guard animated, let previous, let outgoing = pages[previous], outgoing.isShown else {
            detachAll(except: [spaceID])
            slidingSpaceIDs = []
            evict()
            return
        }
        let incomingStart = incomingPresented ?? pager.offset(for: .insertion, width: inputs.layout.width)
        let outgoingStart = presentedOffset(outgoing.host) ?? 0
        // Any third page of an overtaken slide leaves at once.
        detachAll(except: [spaceID, previous])
        slidingSpaceIDs = [spaceID, previous]
        // The outgoing page draws a Space that is no longer selected: nothing this switch changes
        // shows on it, so it stops following the sidebar while it slides out (B104).
        outgoing.setShown(false)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.slideEnded(generation: generation) }
        }
        let slideIn = SpacePagerMotion.slide(from: incomingStart)
        incoming.host.layer?.add(slideIn, forKey: SpacePagerMotion.key)
        // The outgoing page moves the same way, by the same spring, and stays out until detached.
        let slideOut = SpacePagerMotion.slide(from: outgoingStart)
        slideOut.toValue = pager.offset(for: .removal, width: inputs.layout.width)
        slideOut.fillMode = .forwards
        slideOut.isRemovedOnCompletion = false
        outgoing.host.layer?.add(slideOut, forKey: SpacePagerMotion.key)
        CATransaction.commit()
    }

    /// The horizontal offset a page is drawn at by a running slide, nil when it is not sliding.
    private func presentedOffset(_ host: NSView) -> CGFloat? {
        guard let layer = host.layer, layer.animation(forKey: SpacePagerMotion.key) != nil else { return nil }
        return (layer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private func slideEnded(generation: Int) {
        guard generation == slideGeneration, let shownSpaceID else { return }
        detachAll(except: [shownSpaceID])
        slidingSpaceIDs = []
        evict()
        // The page that slid out may have missed changes during the slide.
        prepareHiddenPagesWhenQuiet()
    }

    /// Hides every page but `kept`.
    private func detachAll(except kept: Set<UUID?>) {
        for (id, page) in pages where !kept.contains(id) && page.isShown { detach(page) }
    }

    /// Shows a page: added to the pager the first time, unhidden after that. A page that missed
    /// changes while hidden was brought up to date when the switch was announced
    /// (`bringUpToDate`); anything left updates once after it is shown (`SidebarSpacePageChanges.isShown`).
    private func attach(_ page: Page) {
        page.host.layer?.removeAnimation(forKey: SpacePagerMotion.key)
        // A page still on screen (sliding out of an overtaken switch) follows the sidebar again.
        defer { page.setShown(true) }
        guard !page.isShown else { return }
        refresh(page)
        if let inputs, page.host.frame != pageFrame(inputs.layout) { page.host.frame = pageFrame(inputs.layout) }
        if page.host.superview !== self { addSubview(page.host) }
        pageWillShowForTesting?(page.host.rootView.spaceID)
        page.host.isHidden = false
    }

    /// Hides a page; it stays in the view tree, but is not updated until it is shown again.
    private func detach(_ page: Page) {
        page.host.layer?.removeAnimation(forKey: SpacePagerMotion.key)
        page.host.isHidden = true
        page.setShown(false)
    }

    /// Drops the pages shown longest ago beyond `maxPages`.
    private func evict() {
        while recent.count > SidebarSpacePager.maxPages, let oldest = recent.first(where: { $0 != shownSpaceID && !slidingSpaceIDs.contains($0) }) {
            recent.removeAll { $0 == oldest }
            if let page = pages.removeValue(forKey: oldest) {
                detach(page)
                page.host.removeFromSuperview()
            }
            inputs?.scroll.forget(oldest)
        }
    }
}
