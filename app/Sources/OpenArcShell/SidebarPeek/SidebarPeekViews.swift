import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Views of the hidden-sidebar peek (B34): the floating panel and the window-level pointer tracker.
// [06 §14] observed.

/// The sidebar floating over the web panel: a rounded, shadowed panel 5 pt from the window's top,
/// bottom and left edges, in a deeper, more saturated fill than the pinned sidebar, with a ≈ 2 pt
/// light rim. The web panel under it keeps its frame. [06 §14], [06 §26.2] observed; radius, shadow
/// and the fill / rim rules are local tokens.
struct SidebarPeekOverlay: View {
    @ObservedObject var sidebar: SidebarViewModel
    let siteControls: SiteControlsModel
    let windowSize: CGSize
    /// The window's sidebar width (B144).
    var sidebarWidth: CGFloat = CGFloat(Metrics.Sidebar.width)

    var body: some View {
        let layout = SidebarPeekLayout(windowSize: windowSize, sidebarWidth: sidebarWidth)
        let panel = layout.panelFrame
        let palette = sidebar.palette
        let fill = SidebarPeekTokens.panelFill(for: palette)
        let shape = RoundedRectangle(cornerRadius: SidebarPeekTokens.panelCornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // The sidebar moves with the panel by (5, 5), like the traffic lights the window
            // chrome puts at `WindowButtonPlacement.peek`. [06 §26.2] observed. B54.
            SidebarView(viewModel: sidebar, width: layout.sidebarSize.width)
                .environment(\.siteControlsModel, siteControls)
                .environment(\.sidebarPresentation, .peeking)
                .environment(\.sidebarFillOverride, fill)
                // The floating panel is opaque over the page ([06 §14] observed a solid deeper
                // fill); its controls use the opaque colors. B64.
                .environment(\.windowSurface, .opaque)
                .frame(width: layout.sidebarSize.width, height: layout.sidebarSize.height)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .clipShape(shape)
        // The rim sits inside the panel edge, over the sidebar's outer margin. [06 §26.2] observed.
        .overlay(shape.strokeBorder(SidebarPeekTokens.rimColor(isDark: palette.isDark).swiftUI,
                                    lineWidth: SidebarPeekTokens.rimWidth).allowsHitTesting(false))
        .contentShape(shape)
        .background(
            shape.fill(fill.swiftUI)
                .shadow(color: .black.opacity(SidebarPeekTokens.shadowOpacity), radius: SidebarPeekTokens.shadowRadius,
                        x: SidebarPeekTokens.shadowOffsetX, y: SidebarPeekTokens.shadowOffsetY)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebarPeek")
        .offset(x: panel.minX, y: panel.minY)
    }

    /// Slides in from beyond the window's left edge and back out, by the observed travel
    /// (`collapsedOffset`, [07 §11] observed x −291 → 0), the same distance the traffic lights
    /// move, so both stay together. Curve and duration: `ShellMotion.sidebarPeekSlide`
    /// ([07 §11] unknown). B54.
    static func transition(sidebarWidth: CGFloat) -> AnyTransition {
        .offset(x: -SidebarPeekTokens.collapsedOffset(sidebarWidth: sidebarWidth))
    }
}

/// Reports the pointer position over the whole window, whatever view is under it (the engine's
/// web content view included): tracking areas fire by geometry, not by hit testing. Transparent to
/// clicks. While it is in a window it also watches pointer moves outside the window (local and
/// global mouse-moved monitors), because the left-edge zone reaches past the window's left edge
/// (B145). Points are in window coordinates, top-left origin (negative x left of the window).
struct SidebarPeekTracker: NSViewRepresentable {
    let onMove: @MainActor (CGPoint?, CGSize) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class TrackingView: NSView {
        var onMove: (@MainActor (CGPoint?, CGSize) -> Void)?
        private var area: NSTrackingArea?
        private var monitors: SidebarPeekMonitorBag?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            // Moves outside the window: over the desktop or other apps (global) and over this
            // app's other windows (local). Mouse-moved monitors need no extra permission.
            let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.reportScreenPointer(unlessIn: event.window) }
                return event
            }
            let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportScreenPointer(unlessIn: nil) }
            }
            monitors = SidebarPeekMonitorBag([local, global].compactMap { $0 })
        }

        func stopMonitoring() {
            monitors = nil
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { reportScreenPointer(unlessIn: nil) }

        private func report(_ event: NSEvent) {
            onMove?(windowPoint(event.locationInWindow), windowSize)
        }

        /// The current pointer position, for moves this view's tracking area does not see. Events
        /// of this window are left to the tracking area.
        private func reportScreenPointer(unlessIn eventWindow: NSWindow?) {
            guard let window, eventWindow !== window else { return }
            let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            onMove?(windowPoint(location), windowSize)
        }

        /// The window's content size, the coordinate space the peek layout uses.
        private var windowSize: CGSize { window?.contentView?.bounds.size ?? bounds.size }

        /// A window location (bottom-left origin) as a top-left-origin window point.
        private func windowPoint(_ location: NSPoint) -> CGPoint {
            guard let content = window?.contentView else { return convert(location, from: nil) }
            let p = content.convert(location, from: nil)
            return CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
        }
    }
}

/// Removes event monitors when released.
private final class SidebarPeekMonitorBag {
    private let monitors: [Any]
    init(_ monitors: [Any]) { self.monitors = monitors }
    deinit { monitors.forEach(NSEvent.removeMonitor) }
}
