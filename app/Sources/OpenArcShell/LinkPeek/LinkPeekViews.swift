import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Peek on screen (plan B49): the dimming over the page, the floating panel with the Peek page and
// the round buttons on its right. Geometry: `LinkPeekLayout`; colors and sizes: `PeekMetrics`,
// `PeekColors` ([06 §22.2] observed unless labelled otherwise there).

/// Everything Peek draws over the window. The page behind is shrunk by `MainWindowContent`.
struct LinkPeekOverlay: View {
    @ObservedObject var peek: LinkPeekModel
    let layout: LinkPeekLayout
    let palette: ThemePalette
    /// Set by the window: false while another surface (the command bar) owns Esc.
    var handlesEscape: Bool = true
    @State private var isSettled = false

    var body: some View {
        let panel = layout.panelFrame
        let behind = layout.backgroundFrame
        ZStack(alignment: .topLeading) {
            // A gray veil over the page only; the sidebar is not dimmed. [06 §22.2] observed.
            // A click on it closes Peek. [06 §22.3] observed.
            RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous)
                .fill(PeekColors.dim.swiftUI.opacity(PeekColors.dimOpacity))
                .frame(width: behind.width, height: behind.height)
                .offset(x: behind.minX, y: behind.minY)
                .contentShape(Rectangle())
                .onTapGesture { peek.close() }
                .opacity(isSettled ? 1 : 0)
                .accessibilityLabel("Close Peek")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("openarc.peek.dim")

            LinkPeekPanel(peek: peek, palette: palette)
                .frame(width: panel.width, height: panel.height)
                .clipShape(RoundedRectangle(cornerRadius: PeekMetrics.cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: PeekMetrics.cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(PeekMetrics.shadowOpacity), radius: PeekMetrics.shadowRadius)
                )
                .offset(x: panel.minX, y: panel.minY)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("openarc.peek.panel")

            // The column slides in from 133 pt to the left over ≈ 0.3 s. [06 §22.4] observed;
            // curve unknown (`Motion.peekOpen`).
            ForEach(Array(zip(LinkPeekButtonKind.allCases, layout.buttonFrames)), id: \.0) { kind, frame in
                LinkPeekButton(kind: kind, peek: peek)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX + (isSettled ? 0 : Motion.peekButtonsStartOffsetX), y: frame.minY)
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .background(LinkPeekEscapeMonitor(isActive: handlesEscape, onEscape: { peek.close() }, onOpenInSpace: { peek.openInSpace(nil) }))
        .onAppear {
            withAnimation(ShellMotion.peekOpen) { isSettled = true }
        }
    }
}

/// The panel: the Peek page fills it, with no title bar. [06 §22.2] observed.
private struct LinkPeekPanel: View {
    @ObservedObject var peek: LinkPeekModel
    let palette: ThemePalette
    @Environment(\.windowDrawnPermissionTab) private var windowDrawnPermissionTab

    var body: some View {
        WebPanel(tab: peek.liveTab, background: palette.webPanelBackground, backgroundGradient: palette.webPanelBackgroundGradient)
            .onChange(of: peek.session?.tab) { _, _ in focusPage() }
            .onAppear { focusPage() }
    }

    /// Typing goes to the Peek page (inferred).
    private func focusPage() {
        guard let tab = peek.liveTab else { return }
        DispatchQueue.main.async { tab.surface.setFocused(true) }
    }
}

/// One of the round buttons right of the panel: 34 × 33 dark circle with a light icon. [06 §22.2] observed.
private struct LinkPeekButton: View {
    let kind: LinkPeekButtonKind
    @ObservedObject var peek: LinkPeekModel
    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PeekColors.buttonInk.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(PeekColors.buttonFill.swiftUI.opacity(isHovering ? 1 : 0.9)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("openarc.peek.\(identifier)")
    }

    private func perform() {
        switch kind {
        case .close: peek.close()
        case .expand: peek.expand()
        case .split: peek.openInSplit()
        }
    }

    /// Icons are ours (CLAUDE.md: icons may differ); the order and meaning are observed.
    private var symbol: String {
        switch kind {
        case .close: "xmark"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .split: "rectangle.split.2x1"
        }
    }

    /// [06 §22.2] observed names (`LinkPeekButtonKind.title`).
    private var title: String { kind.title }

    private var identifier: String {
        switch kind {
        case .close: "close"
        case .expand: "expand"
        case .split: "split"
        }
    }
}

/// Esc closes Peek ([06 §22.3] observed); ⌘O opens the Peek page in the current Space ([02 §tabs]
/// observed "Open Little Arc or Peek in…", B82). The page has keyboard focus and the engine keeps
/// keys it does not handle from SwiftUI's shortcuts, so a local key monitor of this window catches
/// both before dispatch.
private struct LinkPeekEscapeMonitor: NSViewRepresentable {
    var isActive: Bool
    let onEscape: () -> Void
    var onOpenInSpace: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onEscape = onEscape
        context.coordinator.onOpenInSpace = onOpenInSpace
        context.coordinator.install()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isActive = true
        var onEscape: () -> Void = {}
        var onOpenInSpace: () -> Void = {}
        private var monitor: Any?

        /// Esc's virtual key code.
        private static let escapeKeyCode: UInt16 = 53
        /// The O key's virtual key code (ANSI layout position; ⌘O is matched by character too).
        private static let oKeyCode: UInt16 = 31

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode, number = event.windowNumber
                let characters = event.charactersIgnoringModifiers?.lowercased()
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
                let handled = MainActor.assumeIsolated {
                    self?.handle(keyCode: keyCode, characters: characters, flags: flags, windowNumber: number) ?? false
                }
                return handled ? nil : event
            }
        }

        /// A plain Esc in this window closes Peek, ⌘O opens it in the Space; returns whether the
        /// key was consumed.
        private func handle(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
            guard isActive, let window = view?.window, window.windowNumber == windowNumber else { return false }
            if keyCode == Self.escapeKeyCode, flags.isEmpty {
                onEscape()
                return true
            }
            if flags == .command, characters == "o" || (characters == nil && keyCode == Self.oKeyCode) {
                onOpenInSpace()
                return true
            }
            return false
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The small dark square over a favorite's top-right corner while its Peek is open.
/// [06 §22.2] observed ≈ 10 × 10.
struct LinkPeekSourceBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: PeekBadgeMetrics.cornerRadius, style: .continuous)
            .fill(PeekColors.sourceBadge.swiftUI)
            .frame(width: PeekBadgeMetrics.size, height: PeekBadgeMetrics.size)
            .offset(x: PeekBadgeMetrics.overhang, y: -PeekBadgeMetrics.overhang)
            .allowsHitTesting(false)
            .accessibilityIdentifier("openarc.peek.sourceBadge")
    }
}
