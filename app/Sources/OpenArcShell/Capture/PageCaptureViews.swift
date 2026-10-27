import SwiftUI
import AppKit
import OpenArcEngine
import OpenArcDesign

// The capture surfaces (plan B51, docs/arc-spec/06-flows.md §24): the region capture overlay over
// the selected page (dim, hint card, first-run tip, selection with its label, frozen image, result
// menu), the portrait mode bubble centered on the web panel, and the notices at the panel's top
// right. Geometry: `PageCaptureGeometry`; tokens: `Metrics.Capture`.

/// Everything the capture tools draw in a browser window. `pageFrame` is the selected page in
/// window coordinates, `panelFrame` the web panel.
struct PageCaptureLayer: View {
    @ObservedObject var capture: PageCaptureModel
    let pageFrame: CGRect?
    let panelFrame: CGRect
    let palette: ThemePalette

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ⇧⌘ + drag anywhere on the page starts a region capture. [06 §24.4] B81. Transparent
            // to hit-testing; it watches the window's mouse events.
            if let pageFrame {
                CaptureShortcutMonitor(capture: capture, size: pageFrame.size)
                    .frame(width: pageFrame.width, height: pageFrame.height)
                    .offset(x: pageFrame.minX, y: pageFrame.minY)
                    .allowsHitTesting(false)
            }
            if let pageFrame, capture.phase != .idle, capture.phase != .portrait, capture.tabID != nil {
                RegionCaptureOverlay(capture: capture, size: pageFrame.size)
                    .frame(width: pageFrame.width, height: pageFrame.height)
                    .offset(x: pageFrame.minX, y: pageFrame.minY)
            }
            if capture.phase == .portrait {
                PortraitCaptureLayer(capture: capture, panelFrame: panelFrame, palette: palette)
            }
            PageCaptureNotices(capture: capture, panelFrame: panelFrame)
        }
    }
}

// MARK: - Region capture (06 §24.1)

struct RegionCaptureOverlay: View {
    @ObservedObject var capture: PageCaptureModel
    let size: CGSize

    private typealias C = Metrics.Capture

    var body: some View {
        let bounds = CGRect(origin: .zero, size: size)
        ZStack(alignment: .topLeading) {
            // ≈ 90 % black over the page, with the selection cut out. [06 §24.1] observed.
            DimmedPage(hole: capture.selection, size: size)
                .allowsHitTesting(false)
            if let selection = capture.selection {
                if let image = capture.regionImage, let nsImage = NSImage(data: image.pngData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: selection.width, height: selection.height)
                        .offset(x: selection.minX, y: selection.minY)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Captured Image")
                        .accessibilityIdentifier("openarc.capture.image")
                }
                Rectangle()
                    .strokeBorder(C.selectionBorderColor.swiftUI, lineWidth: CGFloat(C.selectionBorderWidth))
                    .frame(width: selection.width, height: selection.height)
                    .offset(x: selection.minX, y: selection.minY)
                    .allowsHitTesting(false)
            }
            // Drag target and keyboard (Escape) for every stage.
            CaptureDragSurface(
                acceptsDrag: capture.phase == .selecting,
                onDrag: { capture.dragChanged(from: $0, to: $1, in: bounds) },
                onEnd: { capture.dragEnded(from: $0, to: $1, in: bounds) },
                onEscape: { capture.cancel() }
            )
            .frame(width: size.width, height: size.height)
            if capture.phase == .selecting && capture.selection == nil {
                RegionCaptureHintCard()
                    .frame(width: C.hintCardSize.width, height: C.hintCardSize.height)
                    .offset(x: PageCaptureGeometry.hintCardFrame(in: bounds).minX,
                            y: PageCaptureGeometry.hintCardFrame(in: bounds).minY)
                    .allowsHitTesting(false)
            }
            if let selection = capture.selection {
                let origin = PageCaptureGeometry.selectionLabelOrigin(selection: selection, in: bounds)
                SelectionLabel(number: capture.selectionNumber) { capture.cancel() }
                    .offset(x: origin.x, y: origin.y)
                if capture.phase == .selected {
                    let menu = PageCaptureGeometry.resultMenuFrame(selection: selection, in: bounds)
                    PageCaptureResultMenu(capture: capture)
                        .frame(width: menu.width, height: menu.height)
                        .offset(x: menu.minX, y: menu.minY)
                }
            }
            if capture.showsShortcutTip && capture.phase == .selecting {
                ShortcutTip()
                    .frame(width: size.width - 2 * C.toastTrailingInset, alignment: .trailing)
                    .offset(x: C.toastTrailingInset, y: C.toastTopInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.capture.region")
    }
}

/// The dim with an optional bright hole (even-odd fill).
private struct DimmedPage: View {
    let hole: CGRect?
    let size: CGSize

    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let hole { path.addRect(hole) }
        }
        .fill(Color.black.opacity(Metrics.Capture.dimOpacity), style: FillStyle(eoFill: true))
    }
}

/// "Drag to capture a portion of this page": white rounded card, purple bold text, a colorful
/// glow behind it. [06 §24.1] observed.
private struct RegionCaptureHintCard: View {
    private typealias C = Metrics.Capture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(C.hintCardCornerRadius), style: .continuous)
        Text("Drag to capture a portion of this page")
            .font(.system(size: CGFloat(C.hintTextSize), weight: .bold))
            .foregroundStyle(C.hintTextColor.swiftUI)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.white))
            .background(
                shape.fill(LinearGradient(colors: C.hintGlowColors.map(\.swiftUI), startPoint: .leading, endPoint: .trailing))
                    .blur(radius: CGFloat(C.hintGlowRadius))
                    .opacity(0.9)
            )
            .accessibilityIdentifier("openarc.capture.hint")
    }
}

/// "Next time, hold ⇧⌘ and drag your mouse to capture any time." with key caps, in a dark purple
/// pill at the top right; first region capture only. [06 §24.1] observed.
private struct ShortcutTip: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Next time, hold")
            KeyCap("⇧⌘")
            Text("and drag your mouse to capture any time.")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 14)
        .frame(height: CGFloat(Metrics.Capture.pillHeight))
        .background(Capsule().fill(Metrics.Capture.toastFill.swiftUI))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.capture.shortcutTip")
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.2)))
    }
}

/// "● Page N ✕" at the selection's top-left. [06 §24.1] observed (light, small). The ✕ leaves the
/// capture (inferred).
private struct SelectionLabel: View {
    let number: Int
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Metrics.Capture.hintTextColor.swiftUI).frame(width: 6, height: 6)
            Text("Page \(number)").font(.system(size: 11, weight: .semibold))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Capture")
            .accessibilityIdentifier("openarc.capture.cancel")
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(.horizontal, 8)
        .frame(height: CGFloat(Metrics.Capture.selectionLabelHeight))
        .background(Capsule().fill(Color.white.opacity(0.92)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.capture.selectionLabel")
    }
}

/// The dark menu right of the frozen selection. [06 §24.1] observed items: Send To… (field) ·
/// Save to Library · Copy · Save… · Send via iMessage… · — · Edit · Retake · — · + New Easel.
struct PageCaptureResultMenu: View {
    @ObservedObject var capture: PageCaptureModel
    @State private var sendTo = ""

    private typealias C = Metrics.Capture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Send To's candidates were not captured ([06 §24.5] unknown): the field is inert.
            TextField("Send To…", text: $sendTo)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: CGFloat(C.resultMenuFieldHeight))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                .padding(.bottom, 6)
                .disabled(true)
                .accessibilityIdentifier("openarc.capture.menu.sendTo")
            ForEach(PageCaptureMenuItem.allCases, id: \.self) { item in
                if item.startsGroup {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
                }
                Button { capture.perform(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 18)
                        Text(item.title).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: CGFloat(C.resultMenuRowHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(CaptureMenuRowStyle())
                .disabled(!capture.canPerform(item))
                .accessibilityIdentifier("openarc.capture.menu.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
        .background(RoundedRectangle(cornerRadius: CGFloat(C.resultMenuCornerRadius), style: .continuous).fill(C.resultMenuFill.swiftUI))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.capture.menu")
    }
}

private struct CaptureMenuRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.16 : (isHovering && isEnabled ? 0.1 : 0))))
            .onHover { isHovering = $0 }
    }
}

// MARK: - Drag surface (AppKit)

/// Crosshair cursor, the drag in page points (origin top left) and Escape. It becomes first
/// responder while shown, so Escape reaches it rather than the page.
struct CaptureDragSurface: NSViewRepresentable {
    var acceptsDrag: Bool
    var onDrag: (CGPoint, CGPoint) -> Void
    var onEnd: (CGPoint, CGPoint) -> Void
    var onEscape: () -> Void
    /// A click while drags are off (the portrait bubble's outside area).
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> CaptureDragSurfaceView {
        let view = CaptureDragSurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: CaptureDragSurfaceView, context: Context) { update(nsView) }

    static func dismantleNSView(_ nsView: CaptureDragSurfaceView, coordinator: ()) {
        nsView.resignIfFirstResponder()
    }

    private func update(_ view: CaptureDragSurfaceView) {
        view.acceptsDrag = acceptsDrag
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onEscape = onEscape
        view.onClick = onClick
        view.window?.invalidateCursorRects(for: view)
    }
}

final class CaptureDragSurfaceView: NSView {
    var acceptsDrag = true
    var onDrag: ((CGPoint, CGPoint) -> Void)?
    var onEnd: ((CGPoint, CGPoint) -> Void)?
    var onEscape: (() -> Void)?
    var onClick: (() -> Void)?
    private var start: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    func resignIfFirstResponder() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    /// The crosshair cursor ("cross + small camera" observed; the camera is our omission).
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: acceptsDrag ? .crosshair : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard acceptsDrag else {
            onClick?()
            return
        }
        start = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsDrag, let start else { return }
        onDrag?(start, convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsDrag, let start else { return }
        self.start = nil
        onEnd?(start, convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - ⇧⌘ + drag (06 §24.4)

/// Watches the window's left mouse events over the selected page. A ⇧⌘ press is held back; once
/// it moves past `PageCaptureShortcut.dragThreshold` the region capture starts with that drag as
/// its selection, and the drag's events stay with the capture. A ⇧⌘ press released without a drag
/// is handed to the page after all (press, then release), so ⇧⌘-click on a link still works.
/// inferred ([06 §24.4] untested).
struct CaptureShortcutMonitor: NSViewRepresentable {
    let capture: PageCaptureModel
    let size: CGSize

    func makeNSView(context: Context) -> CaptureShortcutMonitorView {
        let view = CaptureShortcutMonitorView()
        view.capture = capture
        return view
    }

    func updateNSView(_ nsView: CaptureShortcutMonitorView, context: Context) {
        nsView.capture = capture
    }
}

final class CaptureShortcutMonitorView: NSView {
    weak var capture: PageCaptureModel?
    private var monitor: CaptureEventMonitorToken?
    /// The held-back ⇧⌘ press and its point (view space).
    private var pending: (event: NSEvent, start: CGPoint)?
    private var isCapturing = false
    /// A held-back press being handed to the page, so the monitor lets it through.
    private var isReplaying = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor = nil
        pending = nil
        isCapturing = false
        guard window != nil else { return }
        let token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
        monitor = token.map(CaptureEventMonitorToken.init)
    }

    /// Whether the capture takes the event (it then goes no further).
    private func consumes(_ event: NSEvent) -> Bool {
        guard !isReplaying, let window, event.window === window, let capture else { return false }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            pending = nil
            isCapturing = false
            guard PageCaptureShortcut.matches(event.modifierFlags), bounds.contains(point),
                  capture.canStartShortcutCapture else { return false }
            pending = (event, point)
            return true
        case .leftMouseDragged:
            if isCapturing {
                capture.shortcutDragChanged(to: point, in: bounds)
                return true
            }
            guard let held = pending else { return false }
            guard PageCaptureShortcut.isDrag(from: held.start, to: point) else { return true }
            pending = nil
            isCapturing = capture.beginShortcutDrag(from: held.start, to: point, in: bounds)
            guard !isCapturing else { return true }
            replay(held.event, then: event, in: window)
            return true
        case .leftMouseUp:
            if isCapturing {
                isCapturing = false
                capture.shortcutDragEnded(at: point, in: bounds)
                return true
            }
            if let held = pending {
                // A ⇧⌘ click: the page gets its press now, then this release.
                pending = nil
                replay(held.event, then: event, in: window)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Hands the held press to the page, with `next` queued first so a tracking loop the press
    /// starts (inside `sendEvent`) receives it.
    private func replay(_ press: NSEvent, then next: NSEvent, in window: NSWindow) {
        window.postEvent(next, atStart: true)
        isReplaying = true
        defer { isReplaying = false }
        window.sendEvent(press)
    }
}

/// Removes the event monitor when released.
private final class CaptureEventMonitorToken {
    private let monitor: Any
    init(_ monitor: Any) { self.monitor = monitor }
    deinit { NSEvent.removeMonitor(monitor) }
}

// MARK: - Notices (06 §24.1, §24.2)

struct PageCaptureNotices: View {
    @ObservedObject var capture: PageCaptureModel
    let panelFrame: CGRect

    private typealias C = Metrics.Capture

    var body: some View {
        if let toast = capture.toast {
            let size = switch toast {
            case .screenshotCopied: CGSize(width: C.doneToastSize.width, height: C.doneToastSize.height)
            case .savedToLibrary: CGSize(width: 150, height: C.pillHeight)
            case .copiedImage: CGSize(width: 130, height: C.pillHeight)
            }
            let origin = PageCaptureGeometry.toastOrigin(size: size, in: panelFrame)
            Group {
                switch toast {
                case .copiedImage, .savedToLibrary:
                    Text(toast.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: size.width, height: size.height)
                        .background(Capsule().fill(C.toastFill.swiftUI))
                        .accessibilityIdentifier(toast == .copiedImage ? "openarc.capture.copiedImage" : "openarc.capture.savedToLibrary")
                case .screenshotCopied:
                    ScreenshotCopiedBar(capture: capture)
                        .frame(width: size.width, height: size.height)
                }
            }
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity)
        }
    }
}

/// "Screenshot Copied to Clipboard" · Save · share, 317 × 46, fill ≈ #27134C, white text,
/// translucent light buttons. [06 §24.2] observed. The share button is inert (unknown).
private struct ScreenshotCopiedBar: View {
    @ObservedObject var capture: PageCaptureModel

    var body: some View {
        HStack(spacing: 6) {
            Text(PageCaptureToast.screenshotCopied.text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Save") { capture.saveToastImage() }
                .buttonStyle(CaptureToastButtonStyle())
                .accessibilityIdentifier("openarc.capture.toast.save")
            Button {} label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(CaptureToastButtonStyle())
                .disabled(true)
                .accessibilityLabel("Share")
                .accessibilityIdentifier("openarc.capture.toast.share")
        }
        .foregroundStyle(Color.white)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Metrics.Capture.toastFill.swiftUI))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.capture.toast")
    }
}

private struct CaptureToastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.18)))
    }
}

// MARK: - Portrait mode (06 §24.3)

struct PortraitCaptureLayer: View {
    @ObservedObject var capture: PageCaptureModel
    let panelFrame: CGRect
    let palette: ThemePalette

    var body: some View {
        let frame = PageCaptureGeometry.portraitBubbleFrame(in: panelFrame)
        ZStack(alignment: .topLeading) {
            // A click outside closes the bubble (inferred); Escape too.
            CaptureDragSurface(acceptsDrag: false, onDrag: { _, _ in }, onEnd: { _, _ in },
                               onEscape: { capture.cancel() }, onClick: { capture.cancel() })
                .frame(width: panelFrame.width, height: panelFrame.height)
                .offset(x: panelFrame.minX, y: panelFrame.minY)
            FloatingBubbleChrome(size: frame.size, cornerRadius: CGFloat(Metrics.SiteControls.cornerRadius), arrow: nil,
                                 tint: palette.floatingPanelBackground, isDark: palette.isDark, tintOpacity: 1) {
                PortraitCaptureBubble(capture: capture)
            }
            .offset(x: frame.minX, y: frame.minY)
        }
    }
}

/// Primary button · preview (page card on a gradient, watermark toggle at the lower left) ·
/// rainbow background slider (a dot on the left, a color well on the right). [06 §24.3] observed.
struct PortraitCaptureBubble: View {
    @ObservedObject var capture: PageCaptureModel

    private typealias C = Metrics.Capture

    var body: some View {
        VStack(spacing: 10) {
            Button { capture.confirmPortraitCapture() } label: {
                Text("Capture in Portrait Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: CGFloat(C.portraitPrimaryButtonSize.width), height: CGFloat(C.portraitPrimaryButtonSize.height))
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .disabled(capture.portraitPage == nil)
            .accessibilityIdentifier("openarc.capture.portrait.capture")
            preview
            slider
        }
        .padding(CGFloat(C.portraitBubbleInset))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.capture.portrait")
    }

    private var preview: some View {
        let colors = PortraitCaptureComposer.backgroundColors(hue: capture.portraitHue)
            .map { Color(hue: $0.h, saturation: $0.s, brightness: $0.b) }
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Group {
                if let page = capture.portraitPage, let image = NSImage(data: page.pngData) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.6).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: CGFloat(C.portraitThumbnailSize.width), height: CGFloat(C.portraitThumbnailSize.height))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { capture.portraitShowsWatermark.toggle() } label: {
                Image(systemName: capture.portraitShowsWatermark ? "signature" : "nosign")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: CGFloat(C.portraitWatermarkButtonSize), height: CGFloat(C.portraitWatermarkButtonSize))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capture.portraitShowsWatermark ? "watermark-on" : "watermark-off")
            .accessibilityIdentifier("openarc.capture.portrait.watermark")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 124)
    }

    private var slider: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.primary.opacity(0.5)).frame(width: 6, height: 6)
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.7, brightness: 0.95) },
                        startPoint: .leading, endPoint: .trailing))
                    Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 1)
                        .offset(x: CGFloat(capture.portraitHue) * (width - 14))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    capture.portraitHue = min(1, max(0, Double(value.location.x / width)))
                })
            }
            .frame(height: 14)
            .accessibilityLabel("Background Color")
            .accessibilityIdentifier("openarc.capture.portrait.slider")
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                .frame(width: 18, height: 18)
        }
        .frame(height: 20)
    }
}
