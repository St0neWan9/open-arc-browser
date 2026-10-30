import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The web toolbar's own button tooltips (B140, F5-28/64). [06 §17.5] / [04 §网页工具栏] observed:
// hovering a button shows, about half a second later, a tag under the button reading "Go back ⌘ ["
// with the shortcut drawn as key caps. The system help tag cannot draw key caps and uses its own
// delay, so the buttons use this instead. The delay is `Metrics.WebToolbar.tooltipDelaySeconds`
// (inferred, one observation). The tag's own look (fill, font, caps, gap) was not measured: our
// own, unknown.

/// What one tooltip says: a short sentence-case text and the shortcut's keys, each drawn as a cap.
struct WebToolbarTooltip: Hashable, Sendable {
    var text: String
    var keys: [String] = []

    /// The keys as spaced text ("⌘ ["), as the capture reads them. [06 §17.5] observed.
    var keysText: String { keys.joined(separator: " ") }

    // The texts: "Go back ⌘ [" is [06 §17.5] observed; the others follow it in sentence case with
    // the shortcuts of [02 §页面与导航, §复制链接, §窗口与应用] (inferred wording).
    static let back = WebToolbarTooltip(text: "Go back", keys: ["⌘", "["])
    static let forward = WebToolbarTooltip(text: "Go forward", keys: ["⌘", "]"])
    static let reload = WebToolbarTooltip(text: "Refresh the page", keys: ["⌘", "R"])
    static let stop = WebToolbarTooltip(text: "Stop loading")
    static let showSidebar = WebToolbarTooltip(text: "Show sidebar", keys: ["⌘", "S"])
    static let copyLink = WebToolbarTooltip(text: "Copy link", keys: ["⇧", "⌘", "C"])
}

/// Our own look of the tag (not measured, unknown).
enum WebToolbarTooltipTokens {
    static let fill = RGBAColor(hex: 0xF9F9FB)
    static let ink = RGBAColor(hex: 0x1C1C1E)
    static let textStyle = TextStyle(size: 12, weight: .regular)
    static let keyCapStyle = TextStyle(size: 11, weight: .medium)
    static let cornerRadius: CGFloat = 6
    static let height: CGFloat = 22
    static let horizontalPadding: CGFloat = 8
    static let textToKeys: CGFloat = 6
    static let keyCapSpacing: CGFloat = 2
    static let keyCapMinSize = CGSize(width: 16, height: 15)
    static let keyCapRadius: CGFloat = 3.5
    static let keyCapFillOpacity: Double = 0.08
    static let hairlineOpacity: Double = 0.2
    /// Gap between the button's bottom and the tag's top.
    static let gapBelowButton: CGFloat = 4
    /// Room around the tag for its shadow inside the panel.
    static let shadowMargin: CGFloat = 10
    static let shadow = Metrics.PanelShadow(opacity: 0.14, radius: 4, offsetY: 1.5)
}

/// Pure placement: the tag centered under the button, `gapBelowButton` below it, kept inside
/// `bounds` horizontally. Top-left based rectangles in one space.
enum WebToolbarTooltipLayout {
    static func frame(size: CGSize, below button: CGRect, inside bounds: CGRect) -> CGRect {
        var x = button.midX - size.width / 2
        x = max(bounds.minX, min(x, bounds.maxX - size.width))
        return CGRect(x: x, y: button.maxY + WebToolbarTooltipTokens.gapBelowButton, width: size.width, height: size.height)
    }
}

/// When the tag shows: `delay` seconds after the pointer entered the button, hidden at once when it
/// leaves or the button is pressed. [06 §17.5] observed ≈ 0.5 s (inferred value).
@MainActor
final class WebToolbarTooltipTimer: ObservableObject {
    @Published private(set) var isShown = false
    var delay: Double
    private var task: Task<Void, Never>?

    init(delay: Double = Metrics.WebToolbar.tooltipDelaySeconds) {
        self.delay = delay
    }

    func hover(_ inside: Bool) {
        task?.cancel()
        task = nil
        guard inside else {
            if isShown { isShown = false }
            return
        }
        guard !isShown else { return }
        let delay = delay
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.isShown = true
        }
    }

    /// A press hides the tag until the pointer comes back (inferred, like the system help tag).
    func dismiss() {
        task?.cancel()
        task = nil
        if isShown { isShown = false }
    }

    deinit { task?.cancel() }
}

/// The tag: text, then one cap per key.
struct WebToolbarTooltipView: View {
    let tooltip: WebToolbarTooltip

    var body: some View {
        let t = WebToolbarTooltipTokens.self
        let shape = RoundedRectangle(cornerRadius: t.cornerRadius, style: .continuous)
        HStack(spacing: t.textToKeys) {
            Text(tooltip.text).textStyle(t.textStyle, ink: t.ink).lineLimit(1).fixedSize()
            if !tooltip.keys.isEmpty {
                HStack(spacing: t.keyCapSpacing) {
                    ForEach(Array(tooltip.keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .textStyle(t.keyCapStyle, ink: t.ink)
                            .padding(.horizontal, 3)
                            .frame(minWidth: t.keyCapMinSize.width, minHeight: t.keyCapMinSize.height)
                            .background(RoundedRectangle(cornerRadius: t.keyCapRadius, style: .continuous)
                                .fill(t.ink.swiftUI.opacity(t.keyCapFillOpacity)))
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, t.horizontalPadding)
        .frame(height: t.height)
        .background(shape.fill(t.fill.swiftUI))
        .overlay(shape.strokeBorder(Color.black.opacity(t.hairlineOpacity), lineWidth: 0.5))
        .compositingGroup()
        .panelShadow(t.shadow)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shows `tooltip` under this view after the hover delay, in a floating child panel so it can
    /// reach over the page below the toolbar. Replaces `.help` on the web toolbar's buttons.
    func webToolbarTooltip(_ tooltip: WebToolbarTooltip) -> some View {
        modifier(WebToolbarTooltipModifier(tooltip: tooltip))
    }
}

private struct WebToolbarTooltipModifier: ViewModifier {
    let tooltip: WebToolbarTooltip
    @StateObject private var timer = WebToolbarTooltipTimer()

    func body(content: Content) -> some View {
        content
            .onHover { timer.hover($0) }
            .simultaneousGesture(TapGesture().onEnded { timer.dismiss() })
            .background(WebToolbarTooltipPresenter(tooltip: timer.isShown ? tooltip : nil))
    }
}

/// Puts the tag in a borderless child panel under the anchor view (the button's frame).
struct WebToolbarTooltipPresenter: NSViewRepresentable {
    let tooltip: WebToolbarTooltip?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.update(tooltip: tooltip)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.hide()
    }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var panel: FloatingBubblePanel?
        private var host: NSHostingView<AnyView>?

        func hide() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        func update(tooltip: WebToolbarTooltip?) {
            guard let tooltip, let view, let window = view.window else { return hide() }
            let panel = self.panel ?? makePanel()
            let margin = WebToolbarTooltipTokens.shadowMargin
            host?.rootView = AnyView(
                WebToolbarTooltipView(tooltip: tooltip)
                    .padding(margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            let size = NSHostingView(rootView: WebToolbarTooltipView(tooltip: tooltip)).fittingSize
            // The button and the window's content, in window coordinates flipped to top-left.
            let contentHeight = window.contentView?.bounds.height ?? window.frame.height
            let buttonInWindow = view.convert(view.bounds, to: nil)
            let button = CGRect(x: buttonInWindow.minX, y: contentHeight - buttonInWindow.maxY,
                                width: buttonInWindow.width, height: buttonInWindow.height)
            let bounds = CGRect(x: 0, y: 0, width: window.contentView?.bounds.width ?? window.frame.width, height: contentHeight)
            let tag = WebToolbarTooltipLayout.frame(size: size, below: button, inside: bounds)
            let outer = tag.insetBy(dx: -margin, dy: -margin)
            let inWindow = NSRect(x: outer.minX, y: contentHeight - outer.maxY, width: outer.width, height: outer.height)
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
