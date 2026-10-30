import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Small shared pieces: coordinate space, preference key, icons, pasteboard, drop delegates.

enum SidebarCoordinateSpace {
    static let root = "openarc.sidebar.root"
}

/// Where the rows' speaker glyphs report their frames (sidebar root space): the sidebar's scroll
/// state, set by `SidebarView`. A press on a glyph must not select the row. [05 §tab audio
/// indicator] observed.
private struct SidebarAudioGlyphSinkKey: EnvironmentKey {
    static var defaultValue: SidebarListScrollState? { nil }
}

extension EnvironmentValues {
    var sidebarAudioGlyphSink: SidebarListScrollState? {
        get { self[SidebarAudioGlyphSinkKey.self] }
        set { self[SidebarAudioGlyphSinkKey.self] = newValue }
    }
}

@MainActor
enum SidebarPasteboard {
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: - Icons

/// Favicon of a tab: PNG data (live engine icon or the favicon cache, C9) if present, else a
/// placeholder.
struct SidebarFaviconView: View {
    /// What stands in for a missing favicon.
    enum Placeholder {
        /// A globe glyph (Library lists; our own look).
        case globe
        /// A rounded square inset 1 pt in the cell (16 × 16 in the 18 pt cell, radius ≈ 3), filled
        /// with `tint`. [07 §4] observed "placeholder icon radius ≈ 3"; round-1 PX (B32) observed
        /// the 16 pt ink.
        case roundedSquare
    }

    let pngData: Data?
    let size: CGFloat
    let tint: Color
    var placeholder: Placeholder = .globe

    var body: some View {
        Group {
            if let image = SidebarFaviconView.image(pngData) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                switch placeholder {
                case .globe:
                    Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(tint)
                case .roundedSquare:
                    RoundedRectangle(cornerRadius: SidebarLocalTokens.faviconPlaceholderCornerRadius, style: .continuous)
                        .fill(tint)
                        .padding(SidebarLocalTokens.faviconPlaceholderInset)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Decoded images by their bytes, so a row does not decode its PNG on every render.
    @MainActor private static var decoded: [Data: NSImage] = [:]

    @MainActor
    static func image(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        if let image = decoded[data] { return image }
        guard let image = NSImage(data: data) else { return nil }
        // Small icons; a few hundred distinct ones at most in practice (inferred). Bounded anyway.
        if decoded.count > 512 { decoded.removeAll() }
        decoded[data] = image
        return image
    }
}

/// Icon of a Space: an emoji, an SF Symbol name, or a default, in a `size` cell. With `glyphSize`
/// the glyph is drawn at that point size, centered in the cell (sidebar header and dock, B33:
/// the reference draws a ≈ 14 pt glyph in its 26 pt header cell); without it, it fills the cell.
struct SidebarSpaceIconView: View {
    let icon: String?
    let size: CGFloat
    var glyphSize: CGFloat? = nil
    let tint: Color

    var body: some View {
        Group {
            if let icon, let first = icon.unicodeScalars.first, !first.isASCII {
                Text(icon).font(.system(size: (glyphSize ?? size) * 0.9))
            } else if let glyphSize {
                Image(systemName: icon ?? "circle.grid.2x2")
                    .font(.system(size: glyphSize, weight: .regular))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: icon ?? "circle.grid.2x2").resizable().scaledToFit().foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Region reporting

/// Frames of the non-row regions (list viewport, divider, "+ New Tab", favorites, dock icons) in the
/// sidebar root coordinate space. List rows (and the divider and "+ New Tab") do not report: their
/// frames follow from `SidebarListGeometry` and the scroll offset.
struct SidebarDropRegionsKey: PreferenceKey {
    static let defaultValue: [SidebarDropRegion: CGRect] = [:]
    static func reduce(value: inout [SidebarDropRegion: CGRect], nextValue: () -> [SidebarDropRegion: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame as a drop region.
    func sidebarDropRegion(_ region: SidebarDropRegion) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDropRegionsKey.self,
                    value: [region: proxy.frame(in: .named(SidebarCoordinateSpace.root))]
                )
            }
        )
    }
}

// MARK: - Drop delegate

/// The one drop delegate of the sidebar. It hit-tests the pointer against the reported frames
/// (`SidebarDropHitTester`, pure and unit-tested) instead of having a delegate per row, so the
/// result does not depend on how SwiftUI routes nested drop targets.
///
/// Accepts in-app drags (`draggingItem` set by the drag source) and links from other apps (URL).
struct SidebarRootDropDelegate: DropDelegate {
    let viewModel: SidebarViewModel
    /// Built at each callback, from the scroll offset of that moment.
    let geometry: @MainActor () -> SidebarDropGeometry

    private var isInternal: Bool { viewModel.draggingItem != nil }

    func validateDrop(info: DropInfo) -> Bool {
        isInternal || info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        if !isInternal { viewModel.beginExternalDrag() }
        viewModel.updateDropTarget(at: info.location, in: geometry())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !isInternal { viewModel.beginExternalDrag() }
        let accepted = viewModel.updateDropTarget(at: info.location, in: geometry())
        return DropProposal(operation: accepted ? (isInternal ? .move : .copy) : .forbidden)
    }

    func dropExited(info: DropInfo) {
        viewModel.clearDropTarget()
        // An in-app drag may come back; an external one is over when it leaves.
        if !isInternal { viewModel.endDrag() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = SidebarDropHitTester.target(at: info.location, in: geometry(), allowsSplit: viewModel.dragAllowsSplit)
        if isInternal {
            guard let target else {
                viewModel.endDrag()
                return false
            }
            return viewModel.performDrop(on: target)
        }
        guard let target, viewModel.dropPlan(for: target) != nil,
              let provider = info.itemProviders(for: [.url]).first else {
            viewModel.endDrag()
            return false
        }
        let model = viewModel
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                if let url { model.performURLDrop(url, on: target) } else { model.endDrag() }
            }
        }
        return true
    }
}

// MARK: - Drag source (AppKit)

/// The sidebar's drag source. SwiftUI's `onDrag` starts after the system's own threshold, draws a
/// floating row snapshot and offers no session-end callback; [06 §15.1] observed per-axis
/// thresholds (4 pt vertical / 5 pt horizontal), a press that selects the tab at once, and no image
/// following the pointer inside the window. So the sidebar watches the left mouse button itself
/// (a local event monitor that never consumes the press, so clicks, double-clicks and menus keep
/// working) and starts an AppKit dragging session past the threshold.
///
/// A press on the blank list area below the last row moves the window once the mouse moves
/// ([06 §15.1] observed, B110): the same monitor hands that drag to the window.
struct SidebarDragSourceHost: NSViewRepresentable {
    let viewModel: SidebarViewModel
    /// What a press can pick up, computed at the press (rows move with the scroll offset).
    let items: @MainActor () -> [SidebarDragSourceItem]
    /// The blank list area where a drag moves the window, computed at the press. B110.
    var windowMoveArea: @MainActor () -> SidebarWindowMoveArea = { .none }
    /// The sidebar layout, for the drag image's shape zones (B44).
    var layout = SidebarLayout()
    /// False while something covers the sidebar (the window command bar, onboarding): presses
    /// then belong to that surface.
    @Environment(\.sidebarAcceptsPointer) private var acceptsPointer

    func makeNSView(context: Context) -> SidebarDragSourceView {
        let view = SidebarDragSourceView()
        view.viewModel = viewModel
        view.items = pickable
        view.windowMoveArea = movable
        view.layout = layout
        return view
    }

    func updateNSView(_ nsView: SidebarDragSourceView, context: Context) {
        nsView.viewModel = viewModel
        nsView.items = pickable
        nsView.windowMoveArea = movable
        nsView.layout = layout
    }

    private var pickable: @MainActor () -> [SidebarDragSourceItem] {
        if acceptsPointer { return items }
        return { [] }
    }

    private var movable: @MainActor () -> SidebarWindowMoveArea {
        if acceptsPointer { return windowMoveArea }
        return { .none }
    }
}

final class SidebarDragSourceView: NSView, NSDraggingSource {
    weak var viewModel: SidebarViewModel?
    var items: @MainActor () -> [SidebarDragSourceItem] = { [] }
    var windowMoveArea: @MainActor () -> SidebarWindowMoveArea = { .none }
    var layout = SidebarLayout()
    /// The lifted row that follows the pointer (B44, [06 §15.1] E17 observed).
    private let dragImage = SidebarDragImageController()

    /// Removes the event monitor when released (no `deinit` needed on the view).
    private var monitor: SidebarEventMonitorToken?
    /// The press that may become a drag: the picked item and the press point (view space).
    private var pending: (item: SidebarDragItem, start: CGPoint)?
    private var isDragging = false
    /// Frame of the pressed item (sidebar root space), for the drag image's start position.
    private var pendingFrame: CGRect = .zero
    /// A press on the blank list area: its mouse-down event, handed to the window when the mouse
    /// moves (B110).
    private var pendingWindowMove: NSEvent?
    /// The press that `handle` decided turns into a window move; `startPendingWindowMove` runs it.
    private var windowMoveToStart: NSEvent?

    /// Top-left origin, like the sidebar's SwiftUI coordinate space this view covers.
    override var isFlipped: Bool { true }

    /// Transparent to the mouse: the monitor sees events without taking part in hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor = nil
        guard window != nil else { return }
        let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let kind = event.type, location = event.locationInWindow, clicks = event.clickCount
            let flags = event.modifierFlags, number = event.windowNumber
            let consumed = MainActor.assumeIsolated {
                self?.handle(kind, location: location, clickCount: clicks, flags: flags, windowNumber: number) ?? false
            }
            if kind == .leftMouseDown, let self {
                MainActor.assumeIsolated { self.notePress(event) }
            }
            if consumed, let self {
                MainActor.assumeIsolated {
                    self.startPendingDrag(with: event)
                    self.startPendingWindowMove()
                }
            }
            return consumed ? nil : event
        }
        monitor = token.map(SidebarEventMonitorToken.init)
    }

    /// The drag that `handle` decided to start; `startPendingDrag` begins it with the event.
    private var dragToStart: (item: SidebarDragItem, start: CGPoint)?

    /// Returns true when the event starts a drag (the event is then consumed).
    private func handle(_ kind: NSEvent.EventType, location: NSPoint, clickCount: Int, flags: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard let window, windowNumber == window.windowNumber else { return false }
        let point = convert(location, from: nil)
        switch kind {
        case .leftMouseDown:
            pending = nil
            pendingWindowMove = nil
            pressIsWindowMove = false
            guard bounds.contains(point), !isDragging,
                  flags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            let hit: SidebarDragSourceItem
            switch SidebarPressTarget.at(point, items: items(), windowMoveArea: windowMoveArea()) {
            case .item(let item): hit = item
            case .windowMove:
                // Keeps the event for the move; the press itself still reaches the list.
                pressIsWindowMove = true
                return false
            case .none: return false
            }
            guard viewModel?.canStartDrag(hit.item) == true else { return false }
            pending = (hit.item, point)
            pendingFrame = hit.frame
            // [06 §15.1] observed: the press alone selects the tab and brings it to the front.
            if hit.selects(at: point) {
                // A held, already selected row darkens ≈ 1 %. [07 §7] observed.
                viewModel?.pressBegan(hit.item)
                if clickCount == 1 { viewModel?.pressSelect(hit.item) }
            }
            return false
        case .leftMouseDragged:
            if let press = pendingWindowMove {
                // [06 §15.1] observed: dragging from the blank list area moves the window. It
                // starts with the first movement, like a title bar (inferred).
                pendingWindowMove = nil
                windowMoveToStart = press
                return true
            }
            guard let pending, !isDragging else { return false }
            guard SidebarDragThreshold.isExceeded(dx: point.x - pending.start.x, dy: point.y - pending.start.y) else { return false }
            self.pending = nil
            dragToStart = pending
            viewModel?.pressEnded()
            return true
        case .leftMouseUp:
            pending = nil
            pendingWindowMove = nil
            viewModel?.pressEnded()
            return false
        default:
            return false
        }
    }

    /// Set by `handle` for a press on the blank list area; `notePress` keeps its event.
    private var pressIsWindowMove = false

    private func notePress(_ event: NSEvent) {
        if pressIsWindowMove { pendingWindowMove = event }
        pressIsWindowMove = false
    }

    /// Moves the window from the press point; AppKit tracks the mouse until it goes up.
    private func startPendingWindowMove() {
        guard let press = windowMoveToStart else { return }
        windowMoveToStart = nil
        window?.performDrag(with: press)
    }

    private func startPendingDrag(with event: NSEvent) {
        guard let drag = dragToStart else { return }
        dragToStart = nil
        startDrag(drag.item, at: drag.start, event: event)
    }

    private func startDrag(_ item: SidebarDragItem, at point: CGPoint, event: NSEvent) {
        guard let viewModel else { return }
        isDragging = true
        viewModel.beginDrag(item)
        let draggingItem = NSDraggingItem(pasteboardWriter: SidebarDragPayload.makePasteboardItem(item))
        // The session's own image stays invisible: the visible lifted row is drawn by
        // `SidebarDragImageController` in a panel above every window, which can change its shape
        // while the drag is held ([06 §15.1, §15.4, §15.5] E17 observed).
        let isFavorite: Bool = if case .tab(let id) = item, case .favorite? = viewModel.workspace.tabs[id]?.location { true } else { false }
        let sourceFill: CGRect
        if isFavorite {
            sourceFill = pendingFrame
        } else {
            let fill = layout.rowFillFrame
            sourceFill = CGRect(x: fill.minX, y: pendingFrame.minY + fill.minY, width: fill.width, height: fill.height)
        }
        dragImage.begin(content: viewModel.dragImageContent(for: item), palette: viewModel.palette,
                        press: point, sourceFill: sourceFill, isRowSource: !isFavorite)
        let size = SidebarLocalTokens.dragImageSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
        draggingItem.setDraggingFrame(NSRect(x: point.x, y: point.y, width: size, height: size), contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    // MARK: NSDraggingSource

    /// Moves inside the app only: outside it the drag offers nothing. [06 §15.7] observed.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    /// The session is over: dropped (already applied), released outside every target, or Esc.
    /// [06 §15.9] observed: after Esc nothing changes.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        moveDragImage(to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        moveDragImage(to: screenPoint)
    }

    private func moveDragImage(to screenPoint: NSPoint) {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        dragImage.move(sidebarPoint: point, screenPoint: screenPoint, layout: layout)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        dragImage.end()
        viewModel?.dragSessionEnded()
    }
}

/// Removes an `NSEvent` monitor when released.
private final class SidebarEventMonitorToken {
    private let monitor: Any
    init(_ monitor: Any) { self.monitor = monitor }
    deinit { NSEvent.removeMonitor(monitor) }
}

// MARK: - Row interaction (frame reporting, drop feedback)

/// Common behavior of tab, group and folder rows. Drags start in `SidebarDragSourceView`; drops are
/// handled by the root delegate; the insertion line is drawn once by `SidebarDropIndicatorView`.
/// Takes the row's drop state as a value: rows do not observe the view model (B99).
struct SidebarRowInteraction: ViewModifier {
    /// The row is the target of a drop *into* it (a folder receiving the dragged item).
    let isDropInto: Bool

    func body(content: Content) -> some View {
        let radius = CGFloat(Metrics.Sidebar.selectedRowCornerRadius)
        let fill = SidebarLayout().rowFillFrame
        content
            // The source row stays as it is (not dimmed, no gap). [06 §15.1] observed.
            .background(alignment: .topLeading) {
                if isDropInto {
                    // Folder that would receive the drop: a light gray-violet fill, no stroke.
                    // [06 §15.3] observed.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RGBAColor(hex: SidebarLocalTokens.dropIntoRGB).swiftUI)
                        .frame(width: fill.width, height: fill.height)
                        .offset(x: fill.minX, y: fill.minY)
                        .allowsHitTesting(false)
                }
            }
        // Rows do not report their frames: every row has a fixed height, so the frames follow
        // from the list geometry and the scroll offset (`SidebarListGeometry`).
    }
}

extension View {
    func sidebarRowInteraction(isDropInto: Bool) -> some View {
        modifier(SidebarRowInteraction(isDropInto: isDropInto))
    }
}

/// The insertion line: 2 pt, near white, with a hollow ring at its left end. [06 §15.2] observed.
struct SidebarDropIndicatorView: View {
    let line: SidebarDropIndicatorLine
    let color: Color

    var body: some View {
        let ring = SidebarLocalTokens.dropIndicatorRingDiameter
        let thickness = SidebarLocalTokens.dropIndicatorThickness
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: max(0, line.trailing - line.leading - ring + thickness / 2), height: thickness)
                .offset(x: line.leading + ring - thickness / 2, y: line.y - thickness / 2)
            Circle()
                .strokeBorder(color, lineWidth: thickness)
                .frame(width: ring, height: ring)
                .offset(x: line.leading, y: line.y - ring / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Button style

/// A plain button style that does not dim a disabled label: the label sets its own disabled
/// opacity ([07 §2] ≈ 30 %). `.plain` multiplies a disabled label by about 0.6 on top of that,
/// so the glyph read ≈ 18 % in the round-2 comparison (B33, PX).
struct SidebarUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Environment

private struct SidebarAcceptsPointerKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether presses on the sidebar reach it (see `SidebarDragSourceHost`).
    var sidebarAcceptsPointer: Bool {
        get { self[SidebarAcceptsPointerKey.self] }
        set { self[SidebarAcceptsPointerKey.self] = newValue }
    }
}
