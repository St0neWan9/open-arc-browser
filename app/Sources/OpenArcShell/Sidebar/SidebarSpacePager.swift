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
// A hidden page is not updated while away (`SidebarSpacePageChanges`) and catches up in one update
// when it comes back.

/// Tells one kept Space page that an object it draws from (the sidebar view model, or the list
/// scroll state) changed. The page's views observe this instead of that object, so a page that is
/// hidden does no work for the changes made while it is away; it updates once when it is shown
/// again. B104.
@MainActor
final class SidebarSpacePageChanges: ObservableObject {
    /// Whether the page is on screen. A page that missed changes while hidden catches up in the
    /// run loop pass after the one that showed it: the switch draws the page as it was (the same
    /// rows and selection in the usual case), and the catch-up lands during the slide, which runs
    /// on Core Animation layers. Showing happens inside a view update, where publishing is not allowed.
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
    private var isCatchUpScheduled = false

    /// The relayed object is about to change.
    func sourceWillChange() {
        guard isShown else {
            isStale = true
            return
        }
        isStale = false
        publish()
    }

    /// Updates a shown page that missed changes. Runs after the showing pass has drawn; tests call
    /// it to skip the wait.
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
        let listHeight = max(0, layout.dockFrame.minY - layout.listTop)
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
            // switch is published, so the switch does not update it while it slides out.
            spaceWillChange = viewModel.selectedSpaceWillChange.sink { [weak self] next in
                MainActor.assumeIsolated { self?.spaceWillChange(to: next) }
            }
            modelChanges = viewModel.objectWillChange.sink { [weak self] _ in
                // Both objects are main-actor isolated and publish on the main thread.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for page in self.pages.values { page.changes.sourceWillChange() }
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

    /// The sidebar is about to show `next`: the pages of the other Spaces stop following it.
    private func spaceWillChange(to next: UUID?) {
        for (id, page) in pages where id != next { page.setShown(false) }
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
        let incomingStart = incomingPresented ?? pager.offset(for: .insertion)
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
        slideOut.toValue = pager.offset(for: .removal)
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
    }

    /// Hides every page but `kept`.
    private func detachAll(except kept: Set<UUID?>) {
        for (id, page) in pages where !kept.contains(id) && page.isShown { detach(page) }
    }

    /// Shows a page: added to the pager the first time, unhidden after that. A page that missed
    /// changes while hidden updates once (`SidebarSpacePageChanges.isShown`).
    private func attach(_ page: Page) {
        page.host.layer?.removeAnimation(forKey: SpacePagerMotion.key)
        // A page still on screen (sliding out of an overtaken switch) follows the sidebar again.
        defer { page.setShown(true) }
        guard !page.isShown else { return }
        refresh(page)
        if let inputs, page.host.frame != pageFrame(inputs.layout) { page.host.frame = pageFrame(inputs.layout) }
        if page.host.superview !== self { addSubview(page.host) }
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
