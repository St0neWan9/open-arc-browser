import Foundation
import AppKit
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The Easel canvas of a window (plan B56): tool, selection, drag gestures and text editing over
// the selected tab's Easel. The workspace changes go through `TreeOps` (TreeOps+Easel.swift) on
// the window's controller; this model keeps only transient state (the gesture in progress, its
// preview, the selection). Canvas coordinates are points, origin top-left.
//
// Spec: docs/arc-spec/06-flows.md §9 (observed): a full-page canvas, an editable title, a floating
// toolbar (select — selected by default —, image, text, circle, rectangle, arrow, pen, capture/add)
// and an inert "add collaborator" button. What each tool does on the canvas was not captured
// ([00] Easel row: "graphic editing untested"), so the gestures below are inferred: drag to draw a
// shape, click to place a text box, drag the pen to draw, select / move / resize with the select
// tool, ⌫ deletes, ⌘V pastes an image or text, capture/add places a capture of the last used page.

/// What a paste puts on the canvas.
enum EaselPasteContent: Equatable {
    case image(EaselImage)
    case text(String)
}

@MainActor
public final class EaselCanvasModel: ObservableObject {
    /// The toolbar's tools, in the observed order. [06 §9] observed.
    public enum Tool: String, CaseIterable, Sendable {
        case select, image, text, circle, rectangle, arrow, pen
        /// The last button (stacked squares with +): "capture / add". [06 §9] observed button; its
        /// action was not observed. Ours (B122, inferred): captures the visible part of the page
        /// last used in this Space and places it on the canvas, with the page capture of B51.
        case capture

        /// Tools that stay selected after use. Shape tools and text go back to select after one
        /// element, the pen keeps drawing. inferred.
        var isSticky: Bool { self == .pen }
    }

    @Published public private(set) var tool: Tool = .select
    @Published public private(set) var selection: Set<UUID> = []
    /// The text box being edited, if any.
    @Published public private(set) var editingTextID: UUID?
    /// Elements drawn in place of their stored value while a move or resize drag runs.
    @Published private(set) var preview: [UUID: EaselElement] = [:]
    /// The element being drawn (shape drag, pen stroke), not stored yet.
    @Published private(set) var draft: EaselElement?
    /// How often an inert control (collaborators, Share) was used. For tests and diagnostics:
    /// collaboration is out of scope (B56).
    @Published public private(set) var inertActionCount = 0
    @Published public private(set) var lastError: Error?
    /// The capture tool's capture in flight (B122).
    private var captureTask: Task<Void, Never>?

    /// Asks the user for an image file and returns it encoded (`EaselImageEncoder`); nil cancels.
    /// The view installs the open panel; tests install their own.
    var pickImage: (@MainActor () -> EaselImage?)?
    /// Reads the pasteboard for ⌘V. The view installs the system pasteboard; tests their own.
    var readPasteboard: (@MainActor () -> EaselPasteContent?)?
    /// The visible part of the canvas, for placing pasted and picked content. Set by the view.
    var visibleRect: (@MainActor () -> EaselRect)?

    let sidebar: SidebarViewModel
    private var controller: WorkspaceController { sidebar.controller }
    private var gesture: Gesture?
    /// The Easel the transient state belongs to; a change of Easel resets it.
    private var stateEaselID: UUID?
    private var sidebarChanges: AnyCancellable?

    private enum Gesture {
        case move(ids: [UUID], start: EaselPoint, originals: [UUID: EaselElement])
        case resize(original: EaselElement, handle: EaselHandle)
        case draw(kind: EaselElementKind, start: EaselPoint)
        case pen(points: [EaselPoint])
    }

    init(sidebar: SidebarViewModel) {
        self.sidebar = sidebar
        // Workspace changes (this window, other windows, sync) and selection changes redraw.
        sidebarChanges = sidebar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: State

    /// The Easel the window shows: the selected tab's, if it is live.
    public var easelID: UUID? {
        guard let tabID = sidebar.selectedTabID, let id = sidebar.workspace.easelID(ofTab: tabID),
              sidebar.workspace.liveEasel(id) != nil else { return nil }
        return id
    }

    public var easel: Easel? { easelID.flatMap { sidebar.workspace.liveEasel($0) } }

    /// Elements to draw, bottom to top: stored values with the drag preview applied, then the draft.
    var renderedElements: [EaselElement] {
        guard let easelID else { return [] }
        var elements = sidebar.workspace.elements(inEasel: easelID).map { preview[$0.id] ?? $0 }
        if let draft { elements.append(draft) }
        return elements
    }

    /// The stored, live elements of the shown Easel, bottom to top.
    public var elements: [EaselElement] {
        easelID.map { sidebar.workspace.elements(inEasel: $0) } ?? []
    }

    /// The page's color scheme (View ▸ Appearance and the Space's theme: "Websites, Easels, and
    /// Notes will use:", [01 §View] observed).
    var colorScheme: WebColorScheme {
        sidebar.selectedTabID.map { controller.webColorScheme(forTab: $0) } ?? .light
    }

    /// Drops the transient state when the window now shows another Easel (or none).
    private func syncEasel() {
        let current = easelID
        guard current != stateEaselID else { return }
        stateEaselID = current
        tool = .select
        selection = []
        editingTextID = nil
        preview = [:]
        draft = nil
        gesture = nil
    }

    // MARK: Toolbar

    /// A toolbar click. Image opens the file picker at once; capture places a capture of the last
    /// used page (`captureLastPage`). inferred.
    public func selectTool(_ newTool: Tool) {
        syncEasel()
        switch newTool {
        case .image:
            tool = .select
            guard let image = pickImage?() else { return }
            insertImage(image)
        case .capture:
            tool = .select
            captureLastPage()
        default:
            tool = newTool
            if newTool != .select { selection = [] }
        }
    }

    // MARK: Capture tool (B122)

    /// The page the capture tool renders: the most recently active tab of the Easel's Space that
    /// has a live web page (not an Easel). inferred: [06 §9] records the button only.
    var captureSourceTabID: UUID? {
        guard let tabID = sidebar.selectedTabID, let spaceID = sidebar.workspace.tabs[tabID]?.location.spaceID
                ?? sidebar.selectedSpaceID else { return nil }
        let workspace = sidebar.workspace
        return workspace.allTabs(inSpace: spaceID)
            .filter { $0.id != tabID && workspace.easelID(ofTab: $0.id) == nil && sidebar.liveTab(for: $0.id) != nil }
            .max { ($0.lastActiveAt, $0.id.uuidString) < ($1.lastActiveAt, $1.id.uuidString) }?
            .id
    }

    /// The capture tool: renders the visible part of `captureSourceTabID`'s page with the engine's
    /// page capture (B51, [06 §24.1] region capture of the whole view) and places the image in
    /// view, selected, like a picked image. Without such a page it does nothing (lastError says
    /// why). inferred.
    public func captureLastPage() {
        guard let easelID else { return }
        guard let sourceID = captureSourceTabID, let live = sidebar.liveTab(for: sourceID) else {
            lastError = EngineError.engineFailure("No page to capture in this Space")
            return
        }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            let snapshot: EngineSnapshot
            do {
                snapshot = try await live.capture(.visible(nil))
            } catch {
                self?.lastError = error
                return
            }
            guard let self, !Task.isCancelled, self.easelID == easelID else { return }
            guard let bitmap = NSImage(data: snapshot.pngData), let image = EaselImageEncoder.encode(bitmap) else {
                self.lastError = EngineError.engineFailure("The capture could not be read")
                return
            }
            self.insertImage(image)
        }
    }

    /// Waits for the capture tool's capture (tests).
    func settleCapture() async {
        await captureTask?.value
    }

    /// The collaborator button (lower right) and the URL box's Share button: collaboration is out
    /// of scope (B56). [06 §9] observed buttons.
    public func inertCollaborationAction() {
        inertActionCount += 1
    }

    // MARK: Title

    /// Commits the canvas title. A blank title goes back to "Untitled Easel" (inferred).
    public func renameTitle(_ title: String) {
        guard let id = easelID else { return }
        mutate { try TreeOps.renameEasel($0, id: id, title: title, now: $1) }
    }

    // MARK: Pointer

    /// Mouse down on the canvas at `p`. `extend` is ⇧ (add to / remove from the selection).
    public func pointerDown(at p: EaselPoint, extend: Bool = false, clickCount: Int = 1) {
        syncEasel()
        guard easelID != nil else { return }
        gesture = nil
        switch tool {
        case .select:
            beginSelectGesture(at: p, extend: extend, clickCount: clickCount)
        case .text:
            addTextBox(at: p)
        case .circle, .rectangle, .arrow:
            let kind: EaselElementKind = tool == .circle ? .circle : tool == .rectangle ? .rectangle : .arrow
            gesture = .draw(kind: kind, start: p)
        case .pen:
            gesture = .pen(points: [p])
            draft = penElement([p])
        case .image, .capture:
            break
        }
    }

    public func pointerDragged(to p: EaselPoint) {
        guard let gesture else { return }
        switch gesture {
        case .move(let ids, let start, let originals):
            let dx = p.x - start.x, dy = p.y - start.y
            var next: [UUID: EaselElement] = [:]
            for id in ids {
                guard var element = originals[id] else { continue }
                element.frame = element.frame.offsetBy(dx: dx, dy: dy)
                next[id] = element
            }
            preview = next
        case .resize(let original, let handle):
            preview = [original.id: resized(original, handle: handle, to: p)]
        case .draw(let kind, let start):
            draft = shapeElement(kind, from: start, to: p)
        case .pen(var points):
            if let last = points.last, EaselGeometry.distance(last, p) >= Metrics.Easel.penMinimumPointDistance {
                points.append(p)
                self.gesture = .pen(points: points)
                draft = penElement(points)
            }
        }
    }

    public func pointerUp(at p: EaselPoint) {
        pointerDragged(to: p)
        defer {
            gesture = nil
            preview = [:]
            draft = nil
        }
        guard let gesture, let easelID else { return }
        switch gesture {
        case .move(let ids, let start, _):
            let dx = p.x - start.x, dy = p.y - start.y
            guard dx != 0 || dy != 0 else { return }
            mutate { try TreeOps.moveEaselElements($0, ids: ids, dx: dx, dy: dy, now: $1) }
        case .resize(let original, let handle):
            let result = resized(original, handle: handle, to: p)
            mutate { s, now in
                var s = try TreeOps.setEaselElementFrame(s, id: original.id, frame: result.frame, now: now)
                s = try TreeOps.setEaselElementContent(s, id: original.id, content: result.content, now: now)
                return s
            }
        case .draw(let kind, let start):
            var element = shapeElement(kind, from: start, to: p)
            if EaselGeometry.distance(start, p) < Metrics.Easel.minimumElementSide {
                // A click without a drag places a default-sized shape. inferred.
                element = defaultShape(kind, at: start)
            }
            if add(element, to: easelID) { selection = [element.id] }
            if !tool.isSticky { tool = .select }
        case .pen(let points):
            let element = penElement(points)
            _ = add(element, to: easelID)
        }
    }

    // MARK: Text

    /// Double-click on a text box, or a new one: edit it in place.
    public func beginEditingText(_ id: UUID) {
        guard let element = elements.first(where: { $0.id == id }), case .text = element.content else { return }
        selection = [id]
        editingTextID = id
    }

    /// Ends editing. Empty text deletes the box (inferred). `height` is the laid-out height, so the
    /// frame follows the text.
    public func commitText(_ id: UUID, string: String, height: Double? = nil) {
        guard editingTextID == id else { return }
        editingTextID = nil
        guard let element = elements.first(where: { $0.id == id }) else { return }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.remove(id)
            mutate { try TreeOps.deleteEaselElements($0, ids: [id], now: $1) }
            return
        }
        var frame = element.frame
        if let height { frame.height = max(height, Metrics.Easel.minimumElementSide) }
        mutate { s, now in
            var s = try TreeOps.setEaselElementContent(s, id: id, content: .text(string: string), now: now)
            s = try TreeOps.setEaselElementFrame(s, id: id, frame: frame, now: now)
            return s
        }
    }

    // MARK: Commands

    /// ⌫ / Delete: removes the selection.
    public func deleteSelection() {
        guard editingTextID == nil, !selection.isEmpty else { return }
        let ids = elements.map(\.id).filter(selection.contains)
        selection = []
        guard !ids.isEmpty else { return }
        mutate { try TreeOps.deleteEaselElements($0, ids: ids, now: $1) }
    }

    /// ⌘A on the canvas.
    public func selectAll() {
        syncEasel()
        tool = .select
        selection = Set(elements.map(\.id))
    }

    /// Esc: back to the select tool, then clears the selection.
    public func cancel() {
        if tool != .select {
            tool = .select
        } else {
            selection = []
        }
        gesture = nil
        preview = [:]
        draft = nil
    }

    /// ⌘V: an image goes in as an image, text as a text box, both centered in view. Returns
    /// whether anything was added.
    @discardableResult
    public func paste() -> Bool {
        syncEasel()
        guard easelID != nil, let content = readPasteboard?() else { return false }
        switch content {
        case .image(let image):
            return insertImage(image)
        case .text(let string):
            guard let easelID, !string.isEmpty else { return false }
            let size = Metrics.Easel.defaultTextSize
            var element = newElement(kind: .text, frame: EaselGeometry.frame(centeredAt: placementCenter, size: size), content: .text(string: string))
            element.frame.height = max(size.height, Double(string.split(separator: "\n", omittingEmptySubsequences: false).count) * element.style.fontSize * 1.3)
            guard add(element, to: easelID) else { return false }
            selection = [element.id]
            tool = .select
            return true
        }
    }

    /// Places an image centered in view, scaled down to `Metrics.Easel.maxPlacedImageSide`.
    @discardableResult
    func insertImage(_ image: EaselImage) -> Bool {
        guard let easelID, image.fitsInlineLimit else { return false }
        let w = Double(max(image.pixelWidth, 1)), h = Double(max(image.pixelHeight, 1))
        let scale = min(1, Metrics.Easel.maxPlacedImageSide / max(w, h))
        let frame = EaselGeometry.frame(centeredAt: placementCenter, size: Size2D(width: w * scale, height: h * scale))
        let element = newElement(kind: .image, frame: frame, content: .image(image))
        guard add(element, to: easelID) else { return false }
        selection = [element.id]
        tool = .select
        return true
    }

    // MARK: Internals

    private var placementCenter: EaselPoint {
        visibleRect?().center ?? EaselPoint(x: 400, y: 300)
    }

    private func beginSelectGesture(at p: EaselPoint, extend: Bool, clickCount: Int) {
        let current = elements
        if selection.count == 1, let id = selection.first, let element = current.first(where: { $0.id == id }),
           let handle = EaselGeometry.handle(at: p, on: element.frame) {
            gesture = .resize(original: element, handle: handle)
            return
        }
        guard let hit = current.last(where: { EaselGeometry.hits($0, at: p) }) else {
            if !extend { selection = [] }
            return
        }
        if clickCount >= 2, case .text = hit.content {
            beginEditingText(hit.id)
            return
        }
        if extend {
            if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
        } else if !selection.contains(hit.id) {
            selection = [hit.id]
        }
        guard selection.contains(hit.id) else { return }
        let ids = current.map(\.id).filter(selection.contains)
        gesture = .move(ids: ids, start: p, originals: Dictionary(uniqueKeysWithValues: current.filter { selection.contains($0.id) }.map { ($0.id, $0) }))
    }

    private func addTextBox(at p: EaselPoint) {
        guard let easelID else { return }
        let size = Metrics.Easel.defaultTextSize
        let frame = EaselRect(x: p.x, y: p.y - size.height / 2, width: size.width, height: size.height)
        let element = newElement(kind: .text, frame: frame, content: .text(string: ""))
        guard add(element, to: easelID) else { return }
        tool = .select
        beginEditingText(element.id)
    }

    private func resized(_ original: EaselElement, handle: EaselHandle, to p: EaselPoint) -> EaselElement {
        let result = EaselGeometry.resized(original.frame, handle: handle, to: p)
        var element = original
        element.frame = result.frame
        element.content = EaselGeometry.flipped(original.content, x: result.flipX, y: result.flipY)
        return element
    }

    private func shapeElement(_ kind: EaselElementKind, from a: EaselPoint, to b: EaselPoint) -> EaselElement {
        if kind == .arrow {
            let frame = EaselGeometry.grown(EaselRect(corner: a, b))
            let content = EaselElementContent.arrow(start: EaselGeometry.normalize(a, in: frame), end: EaselGeometry.normalize(b, in: frame))
            return newElement(kind: .arrow, frame: frame, content: content, id: draft?.id)
        }
        let content: EaselElementContent = kind == .circle ? .circle : .rectangle
        return newElement(kind: kind, frame: EaselGeometry.grown(EaselRect(corner: a, b)), content: content, id: draft?.id)
    }

    private func defaultShape(_ kind: EaselElementKind, at p: EaselPoint) -> EaselElement {
        let size = Metrics.Easel.defaultShapeSize
        if kind == .arrow {
            return shapeElement(.arrow, from: p, to: EaselPoint(x: p.x + size.width, y: p.y))
        }
        return newElement(kind: kind, frame: EaselGeometry.frame(centeredAt: p, size: size), content: kind == .circle ? .circle : .rectangle, id: draft?.id)
    }

    private func penElement(_ points: [EaselPoint]) -> EaselElement {
        let frame = EaselGeometry.boundingFrame(points)
        return newElement(kind: .pen, frame: frame, content: .pen(points: points.map { EaselGeometry.normalize($0, in: frame) }), id: draft?.id)
    }

    /// An element value with a fresh id (or `id`) and the default style of its kind. Its stacking
    /// key is set when it is stored.
    private func newElement(kind: EaselElementKind, frame: EaselRect, content: EaselElementContent, id: UUID? = nil) -> EaselElement {
        EaselElement(
            id: id ?? controller.makeID(), easelID: easelID ?? UUID(), zKey: .initial, frame: frame,
            content: content, style: EaselTokens.defaultStyle(for: kind), now: controller.now()
        )
    }

    @discardableResult
    private func add(_ element: EaselElement, to easelID: UUID) -> Bool {
        mutate { try TreeOps.addEaselElement($0, id: element.id, easelID: easelID, frame: element.frame, content: element.content, style: element.style, now: $1) }
    }

    @discardableResult
    private func mutate(_ body: (WorkspaceState, Date) throws -> WorkspaceState) -> Bool {
        let now = controller.now()
        do {
            try controller.mutate(origin: sidebar) { try body($0, now) }
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }
}
