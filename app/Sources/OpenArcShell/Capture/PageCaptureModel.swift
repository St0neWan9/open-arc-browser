import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import OpenArcEngine
import OpenArcDesign

// Page capture (plan B51). Spec: docs/arc-spec/06-flows.md §24 (E4, 2026-10-26), with the entry
// points of §12 (Site Control Center: "capture area" camera and "capture full page" buttons) and
// [01 §File] Capture… · Capture Full Page · Capture in Portrait Mode, [02] ⇧⌘2 for Capture….
//
// - Region (§24.1, observed): the page is dimmed, a hint card asks to drag; the dragged rectangle
//   stays bright with a thin border and a label at its top-left; on release the rectangle freezes
//   as the captured image and a dark menu opens to its right (Send To… · Save to Library · Copy ·
//   Save… · Send via iMessage… · Edit · Retake · New Easel). Copy puts the image on the clipboard
//   and shows "Copied Image" with the menu still open. Escape leaves at any stage. Only Copy was
//   tried in the capture; Save… (panel) and Retake (select again) are inferred; Send To, Save to
//   Library, iMessage, Edit and New Easel were never opened (unknown) and stay inert here.
// - Full page (§24.2, observed): no selection; the whole page goes to the clipboard within a second
//   or two and a bar "Screenshot Copied to Clipboard · Save · share" appears at the panel's top
//   right. Save writes the image to the user's Downloads folder (inferred; the spec does not say
//   where); the share button is inert (unknown).
// - Portrait (§24.3, observed): a bubble centered on the web panel first, with a "Capture in
//   Portrait Mode" button, a preview (the page as a portrait card on a gradient, a watermark
//   toggle) and a rainbow background slider; the button copies the image and shows the same bar.
//   The slider's and watermark's effects were not captured (unknown): ours tints the background
//   and draws a small caption.

/// Where a capture is.
public enum PageCapturePhase: Equatable, Sendable {
    case idle
    /// Region capture: dimmed page, waiting for or following a drag. [06 §24.1] observed.
    case selecting
    /// The drag ended; the engine renders the selection.
    case capturingSelection
    /// The selection is frozen as an image with the result menu next to it. [06 §24.1] observed.
    case selected
    /// The portrait mode bubble is up. [06 §24.3] observed.
    case portrait
}

/// The notices of the capture tools. [06 §24.1, §24.2] observed texts.
public enum PageCaptureToast: Equatable, Sendable {
    /// "Copied Image" after the result menu's Copy (a dark purple pill).
    case copiedImage
    /// "Screenshot Copied to Clipboard" with Save and share (full page and portrait mode).
    case screenshotCopied

    public var text: String {
        switch self {
        case .copiedImage: "Copied Image"
        case .screenshotCopied: "Screenshot Copied to Clipboard"
        }
    }
}

/// Items of the region capture's result menu, top to bottom. [06 §24.1] observed titles and order.
public enum PageCaptureMenuItem: String, CaseIterable, Sendable {
    case saveToLibrary, copy, save, sendViaMessages, edit, retake, newEasel

    public var title: String {
        switch self {
        case .saveToLibrary: "Save to Library"
        case .copy: "Copy"
        case .save: "Save…"
        case .sendViaMessages: "Send via iMessage…"
        case .edit: "Edit"
        case .retake: "Retake"
        case .newEasel: "New Easel"
        }
    }

    /// SF Symbols stand-ins (icons may differ, CLAUDE.md).
    public var symbol: String {
        switch self {
        case .saveToLibrary: "circle"
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .sendViaMessages: "message"
        case .edit: "pencil"
        case .retake: "arrow.counterclockwise"
        case .newEasel: "plus"
        }
    }

    /// Items with behavior. Copy is observed; Save… and Retake are inferred. The others were never
    /// opened in the capture (unknown) and stay inert.
    public var isAvailable: Bool {
        switch self {
        case .copy, .save, .retake: true
        case .saveToLibrary, .sendViaMessages, .edit, .newEasel: false
        }
    }

    /// A separator goes before these. [06 §24.1] observed "— · Edit · Retake · — · + New Easel".
    public var startsGroup: Bool { self == .edit || self == .newEasel }
}

/// Puts a captured image on the clipboard. Injected so tests never touch the system pasteboard.
@MainActor
public protocol CaptureImagePasteboard: AnyObject {
    func writePNG(_ png: Data)
}

/// The general pasteboard: PNG plus TIFF for apps that only read TIFF.
@MainActor
public final class SystemCaptureImagePasteboard: CaptureImagePasteboard {
    public init() {}
    public func writePNG(_ png: Data) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        board.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }
}

/// Records writes (tests, previews).
@MainActor
public final class RecordingCaptureImagePasteboard: CaptureImagePasteboard {
    public private(set) var written: [Data] = []
    public init() {}
    public func writePNG(_ png: Data) { written.append(png) }
}

@MainActor
public final class PageCaptureModel: ObservableObject {
    @Published public private(set) var phase: PageCapturePhase = .idle
    /// The selection in the page's points (tab view coordinates, origin top left): the live drag
    /// while selecting, the captured rectangle afterwards.
    @Published public private(set) var selection: CGRect?
    /// The captured region (shown frozen at the selection; what Copy and Save… use).
    @Published public private(set) var regionImage: EngineSnapshot?
    /// The page part of a portrait capture (the bubble's preview), nil while it renders.
    @Published public private(set) var portraitPage: EngineSnapshot?
    @Published public var portraitShowsWatermark = true
    /// Background hue of the portrait card, 0...1 (the rainbow slider).
    @Published public var portraitHue: Double = Metrics.Capture.portraitDefaultHue
    @Published public private(set) var toast: PageCaptureToast?
    /// The first-run tip "Next time, hold ⇧⌘ and drag…". [06 §24.1] observed: only on the first
    /// region capture.
    @Published public private(set) var showsShortcutTip = false
    /// The "Page N" number of the selection label. [06 §24.1] observed "Page N"; what N counts is
    /// unknown: here the selections of this window, from 1.
    @Published public private(set) var selectionNumber = 1
    /// The engine failed the last capture (tests, diagnostics).
    @Published public private(set) var lastError: EngineError?
    /// Where the last Save wrote (tests, diagnostics).
    public private(set) var lastSavedURL: URL?

    /// The model tab and engine tab being captured.
    public private(set) var tabID: UUID?
    public private(set) var engineTabID: EngineTabID?

    var pasteboard: any CaptureImagePasteboard
    /// Folder the notice's Save writes to: the user's Downloads (inferred). Tests use a temp dir.
    var saveDirectory: @MainActor () -> URL? = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    /// Asks where Save… writes (suggested name, folder); nil cancels. nil uses the save panel.
    var chooseSaveURL: (@MainActor (String, URL?) async -> URL?)?
    /// Seconds a notice stays. unknown ([06 §24.5]).
    var toastDuration: Double = Metrics.Capture.toastDuration

    private let sidebar: SidebarViewModel
    private let preferences: AppPreferences
    private let now: () -> Date
    /// The engine tab a capture renders from; resolved per capture.
    private var liveTab: (any BrowserTab)?
    private var work: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?
    private var selectionChanges: AnyCancellable?
    /// Bumped by every new capture or cancel, so a late engine answer of an old one is dropped.
    private var generation = 0
    /// Last toast image, for its Save button.
    private(set) var toastImage: EngineSnapshot?

    init(sidebar: SidebarViewModel, preferences: AppPreferences, pasteboard: any CaptureImagePasteboard, now: @escaping () -> Date) {
        self.sidebar = sidebar
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.now = now
        // Switching tabs leaves a region or portrait capture (inferred: the overlay belongs to the page).
        selectionChanges = sidebar.$selectedTabID.dropFirst().sink { [weak self] id in
            guard let self, self.phase != .idle, id != self.tabID else { return }
            self.cancel()
        }
    }

    public var isActive: Bool { phase != .idle }

    // MARK: Region capture (06 §24.1)

    /// Capture… (⇧⌘2) and the Site Control Center's camera button: dims the page and waits for
    /// a drag. Does nothing without a live page.
    public func beginRegionCapture() {
        guard let target = selectedTarget() else { return }
        cancel()
        bind(target)
        phase = .selecting
        showsShortcutTip = !preferences.hasShownCaptureShortcutTip
        preferences.hasShownCaptureShortcutTip = true
    }

    /// The drag moved: `start` and `current` in page points, `bounds` the visible page.
    public func dragChanged(from start: CGPoint, to current: CGPoint, in bounds: CGRect) {
        guard phase == .selecting else { return }
        selection = PageCaptureGeometry.selection(from: start, to: current, in: bounds)
    }

    /// The drag ended: captures the selection; a tiny one (a click) keeps selecting.
    public func dragEnded(from start: CGPoint, to end: CGPoint, in bounds: CGRect) {
        guard phase == .selecting, let live = liveTab else { return }
        guard let rect = PageCaptureGeometry.selection(from: start, to: end, in: bounds),
              PageCaptureGeometry.isUsable(rect) else {
            selection = nil
            return
        }
        selection = rect
        phase = .capturingSelection
        let area = PageCaptureArea.visible(EngineRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        let token = generation
        work.append(Task { [weak self] in
            do {
                let image = try await live.capture(area)
                guard let self, self.generation == token else { return }
                self.regionImage = image
                self.phase = .selected
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        })
    }

    /// A result menu item. Inert items do nothing (see `PageCaptureMenuItem.isAvailable`).
    public func perform(_ item: PageCaptureMenuItem) {
        guard phase == .selected else { return }
        switch item {
        case .copy: copyRegion()
        case .save: saveRegionWithPanel()
        case .retake: retake()
        case .saveToLibrary, .sendViaMessages, .edit, .newEasel: break
        }
    }

    /// Copy: the image goes to the clipboard, "Copied Image" shows, the menu stays. [06 §24.1] observed.
    public func copyRegion() {
        guard phase == .selected, let image = regionImage else { return }
        pasteboard.writePNG(image.pngData)
        show(.copiedImage, image: image)
    }

    /// Save…: a save panel in Downloads with a dated file name (inferred; [06 §24.5] unknown).
    public func saveRegionWithPanel() {
        guard phase == .selected, let image = regionImage else { return }
        let name = suggestedFileName()
        let folder = saveDirectory()
        let choose = chooseSaveURL ?? { await PageCaptureSavePanel.choose(suggestedName: $0, directory: $1) }
        let token = generation
        work.append(Task { [weak self] in
            guard let url = await choose(name, folder), let self, self.generation == token else { return }
            self.write(image, to: url)
        })
    }

    /// Retake: back to an empty selection on the dimmed page. inferred.
    public func retake() {
        guard phase == .selected || phase == .capturingSelection else { return }
        generation += 1
        regionImage = nil
        selection = nil
        selectionNumber += 1
        phase = .selecting
    }

    /// Escape, the label's ✕, a tab switch: leaves any capture stage, keeping nothing. [06 §24.1] observed.
    public func cancel() {
        generation += 1
        phase = .idle
        selection = nil
        regionImage = nil
        portraitPage = nil
        showsShortcutTip = false
        liveTab = nil
        tabID = nil
        engineTabID = nil
    }

    // MARK: Full page (06 §24.2)

    /// Capture Full Page and the Site Control Center's full page button: the whole page to the
    /// clipboard, then the "Screenshot Copied to Clipboard" bar. No selection step. [06 §24.2] observed.
    public func captureFullPage() {
        guard let target = selectedTarget() else { return }
        cancel()
        let live = target.live
        let token = generation
        work.append(Task { [weak self] in
            do {
                let image = try await live.capture(.fullPage(maximumAspectRatio: nil))
                guard let self, self.generation == token else { return }
                self.pasteboard.writePNG(image.pngData)
                self.show(.screenshotCopied, image: image)
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        })
    }

    // MARK: Portrait mode (06 §24.3)

    /// Capture in Portrait Mode: renders the top of the page for the preview and shows the bubble.
    public func beginPortraitCapture() {
        guard let target = selectedTarget() else { return }
        cancel()
        bind(target)
        phase = .portrait
        let live = target.live
        let token = generation
        work.append(Task { [weak self] in
            do {
                let image = try await live.capture(.fullPage(maximumAspectRatio: Metrics.Capture.portraitPageAspect))
                guard let self, self.generation == token else { return }
                self.portraitPage = image
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        })
    }

    /// The bubble's "Capture in Portrait Mode": the composed card to the clipboard, the bubble
    /// closes and the bar shows. [06 §24.3] observed.
    public func confirmPortraitCapture() {
        guard phase == .portrait, let page = portraitPage,
              let card = PortraitCaptureComposer.compose(page: page, hue: portraitHue, watermark: portraitShowsWatermark) else { return }
        cancel()
        pasteboard.writePNG(card.pngData)
        show(.screenshotCopied, image: card)
    }

    // MARK: Notices

    /// The bar's Save: writes the copied image into the Downloads folder under a dated name.
    /// Only on this click. inferred (the spec does not say where Save writes).
    public func saveToastImage() {
        guard toast == .screenshotCopied, let image = toastImage, let folder = saveDirectory() else { return }
        write(image, to: PageCaptureGeometry.uniqueURL(in: folder, name: suggestedFileName()))
        dismissToast()
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
        toastImage = nil
    }

    // MARK: Helpers

    private func selectedTarget() -> (id: UUID, live: any BrowserTab)? {
        guard let id = sidebar.selectedTabID, sidebar.selectedEaselID == nil, let live = sidebar.liveTab(for: id) else { return nil }
        return (id, live)
    }

    private func bind(_ target: (id: UUID, live: any BrowserTab)) {
        tabID = target.id
        engineTabID = target.live.id
        liveTab = target.live
        lastError = nil
    }

    private func fail(_ error: any Error) {
        lastError = error as? EngineError ?? .engineFailure(String(describing: error))
        cancel()
    }

    private func show(_ notice: PageCaptureToast, image: EngineSnapshot) {
        toast = notice
        toastImage = image
        toastTask?.cancel()
        let duration = toastDuration
        guard duration > 0 else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastImage = nil
        }
    }

    private func write(_ image: EngineSnapshot, to url: URL) {
        do {
            try image.pngData.write(to: url, options: .atomic)
            lastSavedURL = url
        } catch {
            lastError = .engineFailure(error.localizedDescription)
        }
    }

    /// "Screenshot 2026-10-26 at 14.03.09.png", the macOS screenshot pattern. inferred ([06 §24.5]
    /// default file name unknown).
    func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: now())).png"
    }

    /// Waits for pending engine and save work (tests).
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work.removeAll()
            for task in pending { await task.value }
        }
    }

    func stop() {
        cancel()
        work.forEach { $0.cancel() }
        work.removeAll()
        toastTask?.cancel()
    }
}

// MARK: - Geometry

/// Pure placement of the capture surfaces. Rectangles are top-left based points.
enum PageCaptureGeometry {
    private typealias C = Metrics.Capture

    /// The rectangle spanned by a drag, clipped to the visible page; nil when nothing is left.
    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        return rect.isNull ? nil : rect
    }

    /// A drag smaller than this on either side is a click, not a selection. inferred.
    static func isUsable(_ rect: CGRect) -> Bool {
        rect.width >= C.minimumSelectionSide && rect.height >= C.minimumSelectionSide
    }

    /// The hint card: centered, its bottom 37 pt above the panel's bottom. [06 §24.1] observed.
    static func hintCardFrame(in panel: CGRect) -> CGRect {
        let size = C.hintCardSize
        return CGRect(x: panel.midX - size.width / 2, y: panel.maxY - C.hintCardBottomInset - size.height,
                      width: size.width, height: size.height)
    }

    /// The result menu: 13 pt right of the selection, top edges aligned. [06 §24.1] observed.
    /// With no room on the right it goes to the left of the selection, and it is kept inside the
    /// panel. inferred.
    static func resultMenuFrame(selection: CGRect, in panel: CGRect) -> CGRect {
        let size = C.resultMenuSize, gap = C.resultMenuGap, margin = C.resultMenuPanelMargin
        var x = selection.maxX + gap
        if x + size.width > panel.maxX - margin { x = selection.minX - gap - size.width }
        x = max(panel.minX + margin, min(x, panel.maxX - margin - size.width))
        var y = selection.minY
        y = max(panel.minY + margin, min(y, panel.maxY - margin - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Origin of the "● Page N ✕" label: its bottom on the selection's top edge, its left edge
    /// 25 pt left of the selection. [06 §24.1] observed. Kept inside the panel (inferred).
    static func selectionLabelOrigin(selection: CGRect, in panel: CGRect) -> CGPoint {
        let x = max(panel.minX, selection.minX - C.selectionLabelLeadingOutset)
        let y = max(panel.minY, selection.minY - C.selectionLabelHeight)
        return CGPoint(x: x, y: y)
    }

    /// The notice at the panel's top right: 4 pt from the top, 8 from the right. [06 §24.2] observed.
    static func toastOrigin(size: CGSize, in panel: CGRect) -> CGPoint {
        CGPoint(x: panel.maxX - C.toastTrailingInset - size.width, y: panel.minY + C.toastTopInset)
    }

    /// The portrait bubble: centered on the web panel. [06 §24.3] observed.
    static func portraitBubbleFrame(in panel: CGRect) -> CGRect {
        let size = C.portraitBubbleSize
        return CGRect(x: panel.midX - size.width / 2, y: panel.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `name` in `folder`, with " 2", " 3"… before the extension when the file exists.
    static func uniqueURL(in folder: URL, name: String, fileManager: FileManager = .default) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

// MARK: - Portrait card

/// Draws the portrait mode image: the page on a vertical gradient of the chosen hue, with a
/// margin of 8 % of the page width, rounded page corners and an optional caption. The look of the
/// final image was not captured ([06 §24.5] unknown): inferred from the bubble's preview.
enum PortraitCaptureComposer {
    static func compose(page: EngineSnapshot, hue: Double, watermark: Bool) -> EngineSnapshot? {
        guard let rep = NSBitmapImageRep(data: page.pngData), let pageImage = rep.cgImage else { return nil }
        let pageWidth = pageImage.width, pageHeight = pageImage.height
        let margin = Int((Double(pageWidth) * Metrics.Capture.portraitMarginRatio).rounded())
        let width = pageWidth + 2 * margin, height = pageHeight + 2 * margin
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Background gradient, top to bottom (CoreGraphics' origin is bottom left).
        let colors = backgroundColors(hue: hue).map { NSColor(hue: $0.h, saturation: $0.s, brightness: $0.b, alpha: 1).cgColor }
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }
        let pageRect = CGRect(x: margin, y: margin, width: pageWidth, height: pageHeight)
        let radius = CGFloat(max(4, pageWidth / 80))
        context.saveGState()
        context.addPath(CGPath(roundedRect: pageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.interpolationQuality = .none
        context.draw(pageImage, in: pageRect)
        context.restoreGState()
        if watermark { drawCaption(in: context, width: width, margin: margin) }
        guard let output = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: output)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return EngineSnapshot(pngData: png, pixelWidth: width, pixelHeight: height)
    }

    /// The two gradient stops for a slider hue. inferred.
    static func backgroundColors(hue: Double) -> [(h: Double, s: Double, b: Double)] {
        let h = hue.truncatingRemainder(dividingBy: 1)
        return [(h, 0.55, 0.95), ((h + 0.08).truncatingRemainder(dividingBy: 1), 0.75, 0.80)]
    }

    /// Our caption in the bottom margin (Arc's watermark look was not captured).
    private static func drawCaption(in context: CGContext, width: Int, margin: Int) {
        let size = max(10, CGFloat(margin) * 0.35)
        let text = NSAttributedString(string: "Open Arc", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ])
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let textSize = text.size()
        text.draw(at: CGPoint(x: CGFloat(width) - CGFloat(margin) - textSize.width, y: (CGFloat(margin) - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Save panel

@MainActor
enum PageCaptureSavePanel {
    /// A PNG save panel in `directory`; nil when cancelled.
    static func choose(suggestedName: String, directory: URL?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}

// MARK: - Preferences

extension AppPreferences {
    static let captureShortcutTipKey = "\(keyPrefix)capture.shortcutTipShown"

    /// The region capture's first-run tip was shown. [06 §24.1] observed: only the first time. Per device.
    var hasShownCaptureShortcutTip: Bool {
        get { boolValue(Self.captureShortcutTipKey) ?? false }
        set { setBool(newValue, Self.captureShortcutTipKey) }
    }
}
