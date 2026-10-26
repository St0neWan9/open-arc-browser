import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The tab-row hover card. [07 §12] observed: Arc shows it in its own floating window at the
// pointer (11.5 pt right, 5.5 pt below), not at a fixed place under the row, and it extends past
// the sidebar over the web panel. It stays where it appeared until it goes away; hovering another
// row shows a new card at the pointer.

/// Card body: title and "Double-click to rename" on the selected-row fill, a speech-bubble corner
/// (small radius) at the top left next to the pointer, a soft shadow. [07 §12] observed shape;
/// colors and shadow inferred.
struct SidebarHoverCardView: View {
    let title: String
    let fill: RGBAColor

    var body: some View {
        let h = Metrics.HoverCard.self
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: CGFloat(h.pointerCornerRadius), bottomLeadingRadius: CGFloat(h.cornerRadius),
            bottomTrailingRadius: CGFloat(h.cornerRadius), topTrailingRadius: CGFloat(h.cornerRadius), style: .continuous
        )
        VStack(alignment: .leading, spacing: 1) {
            Text(title.isEmpty ? "New Tab" : title)
                .textStyle(Typography.hoverCardTitle, ink: RGBAColor(hex: SidebarLocalTokens.cardTextRGB))
                .lineLimit(1)
            Text(SidebarLocalTokens.hoverCardHint)
                .textStyle(Typography.hoverCardHint, ink: RGBAColor(hex: SidebarLocalTokens.cardTextRGB))
                .lineLimit(1)
        }
        .padding(.horizontal, CGFloat(h.horizontalPadding))
        .padding(.vertical, CGFloat(h.verticalPadding))
        .frame(maxWidth: CGFloat(SidebarLocalTokens.hoverCardMaxWidth), alignment: .leading)
        .fixedSize()
        .background(shape.fill(fill.swiftUI))
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shows the hover card for `tabID` in a floating panel at the pointer, while `tabID` is set.
struct SidebarHoverCardPresenter: NSViewRepresentable {
    let tabID: UUID?
    let title: String
    let fill: RGBAColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(tabID: tabID, title: title, fill: fill)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.update(tabID: nil, title: "", fill: RGBAColor(hex: 0xFFFFFF))
    }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var panel: FloatingBubblePanel?
        private var host: NSHostingView<AnyView>?
        private var shownID: UUID?

        /// Room around the card for its shadow.
        static let shadowMargin: CGFloat = 20

        func update(tabID: UUID?, title: String, fill: RGBAColor) {
            guard let tabID, let window = view?.window else {
                if let panel {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
                shownID = nil
                return
            }
            let h = Metrics.HoverCard.self
            let card = SidebarHoverCardView(title: title, fill: fill)
            let content = AnyView(
                card
                    .shadow(color: .black.opacity(h.shadowOpacity), radius: CGFloat(h.shadowRadius))
                    .padding(Self.shadowMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            let panel = self.panel ?? makePanel()
            host?.rootView = content
            guard shownID != tabID else { return }
            shownID = tabID
            // Placed once, at the pointer. [07 §12] observed.
            let cardSize = NSHostingView(rootView: card).fittingSize
            let screen = window.screen ?? NSScreen.main
            let screenFrame = screen?.frame ?? .zero
            let visible = FloatingBubbleLayout.flip(screen?.visibleFrame ?? .zero, height: screenFrame.maxY)
            let mouse = NSEvent.mouseLocation
            let pointer = CGPoint(x: mouse.x, y: screenFrame.maxY - mouse.y)
            let rect = FloatingBubbleLayout.hoverCard(pointer: pointer, size: cardSize, screen: visible)
            let outer = FloatingBubbleLayout.flip(rect, height: screenFrame.maxY).insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin)
            panel.setFrame(outer, display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }

        private func makePanel() -> FloatingBubblePanel {
            let panel = FloatingBubblePanel(contentRect: .zero)
            panel.ignoresMouseEvents = true
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
            self.host = host
            return panel
        }
    }
}
