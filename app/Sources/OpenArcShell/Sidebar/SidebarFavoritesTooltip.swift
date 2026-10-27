import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The favorites hover card (plan B89). [07 §12] observed: hovering a favorite block shows a
// 240 × 64 near-white card (radius 11, 0.5 pt dark outer line, a shadow darker below than above)
// right of the block and vertically centered on it; it reaches past the sidebar over the web page,
// so it lives in its own child panel like the tab hover card. It replaces the system tooltip.

/// Pure placement of the card. Rectangles are top-left based, in the same space as `block`.
enum SidebarFavoritesTooltipLayout {
    static var size: CGSize {
        CGSize(width: Metrics.FavoritesTooltip.size.width, height: Metrics.FavoritesTooltip.size.height)
    }

    /// The card for a hovered block: its left edge `leadingFromBlockTrailing` from the block's
    /// right edge (x 264 for a block ending at 268), vertically centered on the block. [07 §12]
    /// observed.
    static func cardFrame(block: CGRect) -> CGRect {
        let s = size
        return CGRect(x: block.maxX + CGFloat(Metrics.FavoritesTooltip.leadingFromBlockTrailing),
                      y: block.midY - s.height / 2, width: s.width, height: s.height)
    }
}

/// Card body: the favorite's title, then the unread tip when its badge is on ([06 §12] observed
/// text "No unread emails, you can exhale! 🌿").
struct SidebarFavoritesTooltipView: View {
    let title: String
    let detail: String?

    var body: some View {
        let t = Metrics.FavoritesTooltip.self
        let shape = RoundedRectangle(cornerRadius: CGFloat(t.cornerRadius), style: .continuous)
        let ink = RGBAColor(hex: SidebarLocalTokens.cardTextRGB)
        VStack(alignment: .leading, spacing: 1) {
            Text(title.isEmpty ? "New Tab" : title)
                .textStyle(Typography.favoritesTooltipTitle, ink: ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .textStyle(Typography.favoritesTooltipDetail, ink: ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, CGFloat(t.horizontalPadding))
        .frame(width: SidebarFavoritesTooltipLayout.size.width, height: SidebarFavoritesTooltipLayout.size.height,
               alignment: .leading)
        .background(shape.fill(RGBAColor(hex: t.fillRGB).swiftUI))
        .overlay(shape.strokeBorder(Color.black.opacity(t.hairlineOpacity), lineWidth: CGFloat(t.hairlineWidth)))
        .compositingGroup()
        .panelShadow(t.shadow)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shows the card for the hovered favorite in a floating child panel. Placed by the block frame
/// `block`, given in this view's own (top-left) space; the view covers the favorites block.
struct SidebarFavoritesTooltipPresenter: NSViewRepresentable {
    let block: CGRect?
    let title: String
    let detail: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.update(block: block, title: title, detail: detail)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.hide()
    }

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var panel: FloatingBubblePanel?
        private var host: NSHostingView<AnyView>?

        /// Room around the card for its shadow.
        static let shadowMargin: CGFloat = 16

        func hide() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        func update(block: CGRect?, title: String, detail: String?) {
            guard let block, let view, let window = view.window else { return hide() }
            let panel = self.panel ?? makePanel()
            host?.rootView = AnyView(
                SidebarFavoritesTooltipView(title: title, detail: detail)
                    .padding(Self.shadowMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            let card = SidebarFavoritesTooltipLayout.cardFrame(block: block)
            let inWindow = view.convert(card.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), to: nil)
            let frame = window.convertToScreen(inWindow)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            if !panel.isVisible { panel.orderFront(nil) }
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
