import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Presents our floating bubbles in a borderless child panel (see FloatingBubbleViews.swift for
// why not `NSPopover`). The anchor is an invisible AppKit view placed behind the SwiftUI view the
// bubble belongs to; placement comes from `FloatingBubbleLayout` ([07 §12] observed).

/// Why a bubble went away.
enum FloatingBubbleDismissReason: Equatable, Sendable {
    case clickOutside, escape, appDeactivated, windowClosed
}

/// Chrome of one bubble. The tint follows the theme being shown (`ThemePalette.floatingPanelBackground`).
struct FloatingBubbleStyle {
    var width: CGFloat
    /// Fixed bubble height; nil measures the content at `width`.
    var height: CGFloat?
    var cornerRadius: CGFloat
    var tint: RGBAColor
    var isDark: Bool
}

/// What the anchor asks for while the bubble is up.
struct FloatingBubbleRequest {
    enum Placement {
        /// Attached to the anchor view, with an arrow toward it.
        case attached(FloatingBubbleSide)
        /// Edit Theme… from a menu: next to the web panel at the pointer's height, no arrow.
        case editTheme(webPanelMinX: CGFloat)
    }

    var placement: Placement
    var style: FloatingBubbleStyle
    var content: AnyView
    var onDismiss: (FloatingBubbleDismissReason) -> Void
}

extension View {
    /// Shows `request()` in a floating bubble while `isPresented` is true. The view this modifier
    /// is applied to is the anchor.
    func floatingBubble(isPresented: Bool, _ request: @escaping () -> FloatingBubbleRequest) -> some View {
        background(FloatingBubbleAnchor(request: isPresented ? request() : nil))
    }
}

/// The invisible anchor view. Updates are coalesced to the next run-loop turn: the panel is
/// never touched while SwiftUI updates the view graph.
struct FloatingBubbleAnchor: NSViewRepresentable {
    let request: FloatingBubbleRequest?

    func makeCoordinator() -> FloatingBubbleController { FloatingBubbleController() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak controller = context.coordinator] in controller?.schedule() }
        context.coordinator.anchorView = view
        context.coordinator.request = request
        context.coordinator.schedule()
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.request = request
        context.coordinator.schedule()
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: FloatingBubbleController) {
        coordinator.request = nil
        coordinator.hide()
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
final class FloatingBubbleController: NSObject {
    weak var anchorView: NSView?
    var request: FloatingBubbleRequest?

    private(set) var panel: FloatingBubblePanel?
    private var host: FloatingBubbleHostingView<AnyView>?
    private var effect: NSVisualEffectView?
    private weak var parent: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isScheduled = false
    /// Pointer height captured when an Edit Theme bubble opens; it stays put afterwards.
    private var editThemePointerY: CGFloat?
    /// Last frame applied, in the parent's content coordinates.
    private(set) var appliedFrame: FloatingBubbleFrame?

    func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isScheduled = false
                self?.apply()
            }
        }
    }

    /// Hides the bubble without reporting a dismissal (the owner already closed it).
    func hide() {
        removeMonitors()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        editThemePointerY = nil
        appliedFrame = nil
    }

    private func dismiss(_ reason: FloatingBubbleDismissReason) {
        let onDismiss = request?.onDismiss
        hide()
        onDismiss?(reason)
    }

    private func apply() {
        guard let request, let anchorView, let window = anchorView.window, let contentView = window.contentView else {
            hide()
            return
        }
        let containerInWindow = contentView.convert(contentView.bounds, to: nil)
        let container = CGRect(origin: .zero, size: containerInWindow.size)
        func topLeft(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - containerInWindow.minX, y: containerInWindow.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        let style = request.style
        let height = style.height ?? Self.fittingHeight(of: request.content, width: style.width)
        let size = CGSize(width: style.width, height: height)
        let placement: FloatingBubblePlacement
        switch request.placement {
        case .attached(let side):
            placement = .attached(anchor: topLeft(anchorView.convert(anchorView.bounds, to: nil)), side: side)
        case .editTheme(let webPanelMinX):
            if editThemePointerY == nil {
                let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                editThemePointerY = containerInWindow.maxY - pointer.y
            }
            placement = .editTheme(pointerY: editThemePointerY ?? container.midY, webPanelMinX: webPanelMinX)
        }
        let frame = FloatingBubbleLayout.frame(for: placement, size: size, container: container, cornerRadius: style.cornerRadius)
        let outer = frame.outerFrame
        let chrome = FloatingBubbleChrome(size: size, cornerRadius: style.cornerRadius, arrow: frame.arrow,
                                          tint: style.tint, isDark: style.isDark) { request.content }

        let panel = self.panel ?? makePanel()
        host?.rootView = AnyView(chrome)
        panel.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        let inWindow = CGRect(x: containerInWindow.minX + outer.minX, y: containerInWindow.maxY - outer.maxY,
                              width: outer.width, height: outer.height)
        let screenFrame = window.convertToScreen(inWindow)
        if panel.frame != screenFrame || appliedFrame != frame {
            panel.setFrame(screenFrame, display: true)
            effect?.maskImage = Self.maskImage(size: outer.size, cornerRadius: style.cornerRadius, arrow: frame.arrow)
        }
        appliedFrame = frame
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            observe(window)
        }
        if !panel.isVisible { panel.orderFront(nil) }
        installMonitors()
    }

    private func makePanel() -> FloatingBubblePanel {
        let panel = FloatingBubblePanel(contentRect: .zero)
        // The bubble is translucent over what is behind it [07 §12] observed: a blur behind the
        // tint, masked to the bubble shape so nothing shows outside the rounded corners.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        let host = FloatingBubbleHostingView(rootView: AnyView(EmptyView()))
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        effect.addSubview(host)
        panel.contentView = effect
        self.panel = panel
        self.effect = effect
        self.host = host
        return panel
    }

    // MARK: Dismissal

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                // By screen position: a press on the bubble may arrive with no window when the
                // panel is not key. Menus opened from the bubble are their own windows: not outside.
                let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
                if panel.frame.contains(location) || event.window === panel || event.window?.parent === panel { return }
                if let window = event.window, window !== panel.parent, window.level.rawValue > NSWindow.Level.normal.rawValue { return }
                self.dismiss(.clickOutside)
            }
            return event
        }) { monitors.append(down) }
        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel?.isVisible == true, event.keyCode == 53 else { return false }
                self.dismiss(.escape)
                return true
            }
            return handled ? nil : event
        }) { monitors.append(key) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.appDeactivated) }
        })
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(.windowClosed) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: Helpers

    /// Height of `content` laid out at `width`.
    static func fittingHeight(of content: AnyView, width: CGFloat) -> CGFloat {
        let probe = NSHostingView(rootView: content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        return ceil(probe.fittingSize.height)
    }

    /// Mask for the blur: opaque inside the bubble shape, clear outside.
    static func maskImage(size: CGSize, cornerRadius: CGFloat, arrow: FloatingBubbleArrow?) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(FloatingBubbleShape.cgPath(in: rect, cornerRadius: cornerRadius, arrow: arrow))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
    }
}
