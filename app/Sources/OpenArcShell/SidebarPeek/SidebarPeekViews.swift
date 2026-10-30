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

    var body: some View {
        let layout = SidebarPeekLayout(windowSize: windowSize)
        let panel = layout.panelFrame
        let palette = sidebar.palette
        let fill = SidebarPeekTokens.panelFill(for: palette)
        let shape = RoundedRectangle(cornerRadius: SidebarPeekTokens.panelCornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // The sidebar moves with the panel by (5, 5), like the traffic lights the window
            // chrome puts at `WindowButtonPlacement.peek`. [06 §26.2] observed. B54.
            SidebarView(viewModel: sidebar)
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
    static func transition(windowSize: CGSize) -> AnyTransition {
        .offset(x: -SidebarPeekTokens.collapsedOffset)
    }
}

/// Reports the pointer position over the whole window, whatever view is under it (the engine's
/// web content view included): tracking areas fire by geometry, not by hit testing. Transparent to
/// clicks. Points are in window coordinates, top-left origin; nil when the pointer left the window.
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

    final class TrackingView: NSView {
        var onMove: (@MainActor (CGPoint?, CGSize) -> Void)?
        private var area: NSTrackingArea?

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

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil, windowSize) }

        private func report(_ event: NSEvent) {
            onMove?(windowPoint(event.locationInWindow), windowSize)
        }

        /// The window's content size, the coordinate space the peek layout uses.
        private var windowSize: CGSize { window?.contentView?.bounds.size ?? bounds.size }

        /// `locationInWindow` (bottom-left origin) as a top-left-origin window point.
        private func windowPoint(_ location: NSPoint) -> CGPoint {
            guard let content = window?.contentView else { return convert(location, from: nil) }
            let p = content.convert(location, from: nil)
            return CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
        }
    }
}
