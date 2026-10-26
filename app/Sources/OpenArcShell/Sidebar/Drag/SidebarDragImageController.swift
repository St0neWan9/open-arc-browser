import AppKit
import SwiftUI
import OpenArcDesign

// The floating drag image of a sidebar drag.
//
// Arc draws its drag image in an overlay window above everything, so it shows over the web panel
// and outside the browser window as well ([06 §15.1] E17 observed). Ours: the AppKit drag session
// keeps its invisible 1 pt image (it only carries the private payload, [06 §15.7]), and this
// controller shows the image in a small borderless panel at the system dragging-window level that
// follows the session's pointer (`NSDraggingSource.draggingSession(_:movedTo:)`). The panel ignores
// the mouse, so the drop targets under it keep receiving the drag.

@MainActor
final class SidebarDragImageController {
    private var panel: FloatingBubblePanel?
    private var host: NSHostingView<SidebarDragImageView>?

    private var content = SidebarDragImageContent(title: "", icon: .favicon(nil), accessory: .none)
    private var style: SidebarDragImageStyle?
    private var grab = CGPoint(x: 0.5, y: 0.5)
    private(set) var shape: SidebarDragImageShape = .row
    private(set) var isShowing = false

    /// Starts showing the image. `press` and `sourceFill` are in the sidebar root space; the grab
    /// point keeps the press position relative to the image. [06 §15.1] observed.
    func begin(content: SidebarDragImageContent, palette: ThemePalette, press: CGPoint, sourceFill: CGRect, isRowSource: Bool) {
        self.content = content
        style = SidebarDragImageStyle(palette: palette)
        let imageFrame = isRowSource ? SidebarDragImageGeometry.initialFrame(sourceFill: sourceFill) : sourceFill
        grab = SidebarDragImageGeometry.grabFraction(press: press, imageFrame: imageFrame)
        isShowing = true
    }

    /// Moves the image to the pointer. `sidebarPoint` is the pointer in the sidebar root space (it
    /// decides the shape); `screenPoint` is the same pointer on screen (AppKit coordinates).
    func move(sidebarPoint: CGPoint, screenPoint: NSPoint, layout: SidebarLayout) {
        guard isShowing, let style else { return }
        let newShape = SidebarDragImageGeometry.shape(at: sidebarPoint, layout: layout)
        let panel = self.panel ?? makePanel()
        if newShape != shape || host?.rootView.content != content || host?.rootView.style != style {
            shape = newShape
            host?.rootView = SidebarDragImageView(shape: shape, content: content, style: style)
        }
        // Image frame relative to the pointer (y down), then the panel frame on screen (y up).
        let image = SidebarDragImageGeometry.frame(pointer: .zero, grab: grab, shape: shape)
        let margin = CGFloat(Metrics.SidebarDrag.shadowMargin)
        let outer = image.insetBy(dx: -margin, dy: -margin)
        let frame = NSRect(x: screenPoint.x + outer.minX, y: screenPoint.y - outer.maxY,
                           width: outer.width, height: outer.height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Hides the image (drop, cancel, Esc). No animation back to the source ([06 §15.9] observed:
    /// the indicators disappear at once).
    func end() {
        isShowing = false
        shape = .row
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingBubblePanel {
        let panel = FloatingBubblePanel(contentRect: .zero)
        panel.ignoresMouseEvents = true
        // The system level for drag images: above normal windows, floating panels and menus.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: SidebarDragImageView(
            shape: shape, content: content, style: style ?? SidebarDragImageStyle(palette: ThemeDerivation.palette(for: nil))
        ))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    /// The panel, for tests.
    var panelForTesting: NSPanel? { panel }
}
