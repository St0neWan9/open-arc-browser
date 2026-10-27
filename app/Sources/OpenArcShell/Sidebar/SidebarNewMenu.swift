import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The dock "+" New menu (plan B75). [06 §23] observed: a separate floating panel, 222 × 308, its
// lower-left corner just above the dock's "+" button; six rows in three groups
// (New Space · New Folder ‖ New Easel · New Boost ‖ New Split · New Tab), each with an icon on
// the left, the title and a gray key hint on the right; a dark panel in dark appearance. No New
// Note. [04 §floating panels] observed (222 × 308, above the "+" button). An incognito window's
// "+" opens the command bar instead ([06 §20.2] observed, `dockPlusClicked`).

/// One row of the New menu.
enum SidebarNewMenuItem: CaseIterable, Equatable, Sendable {
    case newSpace, newFolder, newEasel, newBoost, newSplit, newTab

    /// The rows in their groups, top to bottom. [06 §23] observed.
    static let groups: [[SidebarNewMenuItem]] = [[.newSpace, .newFolder], [.newEasel, .newBoost], [.newSplit, .newTab]]

    /// Row title. [06 §23] observed.
    var title: String {
        switch self {
        case .newSpace: "New Space"
        case .newFolder: "New Folder"
        case .newEasel: "New Easel"
        case .newBoost: "New Boost"
        case .newSplit: "New Split"
        case .newTab: "New Tab"
        }
    }

    /// Gray key hint at the right. [06 §23] observed (⌃⇧E, ⌃⇧=, ⌘T; none on the other rows),
    /// matching `02` (New Easel ⌃⇧E, Add Split View ⌃⇧=, New Tab ⌘T).
    var keyHint: String? {
        switch self {
        case .newEasel: "⌃⇧E"
        case .newSplit: "⌃⇧="
        case .newTab: "⌘T"
        case .newSpace, .newFolder, .newBoost: nil
        }
    }

    /// Left icon. Our own SF Symbols (icons may differ from the reference, CLAUDE.md).
    var symbol: String {
        switch self {
        case .newSpace: "square.stack"
        case .newFolder: "folder"
        case .newEasel: "scribble.variable"
        case .newBoost: "paintbrush.pointed"
        case .newSplit: "rectangle.split.2x1"
        case .newTab: "plus.square.on.square"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .newSpace: "openarc.sidebar.newMenu.newSpace"
        case .newFolder: "openarc.sidebar.newMenu.newFolder"
        case .newEasel: "openarc.sidebar.newMenu.newEasel"
        case .newBoost: "openarc.sidebar.newMenu.newBoost"
        case .newSplit: "openarc.sidebar.newMenu.newSplit"
        case .newTab: "openarc.sidebar.newMenu.newTab"
        }
    }
}

/// Size and placement of the New menu. Rectangles are window content coordinates, top-left based.
enum SidebarNewMenuLayout {
    /// Panel size. [06 §23], [04 §floating panels] observed (222 × 308).
    static let size = CGSize(width: 222, height: 308)
    /// Gap between the panel's bottom edge and the "+" button's top edge. [06 §23] observed
    /// "lower-left corner just above the button"; 0 is inferred.
    static let gapAboveButton: CGFloat = 0
    /// Inner padding above the first and below the last row. inferred (not measured).
    static let verticalInset: CGFloat = 10
    /// Inner padding left and right of the rows. inferred.
    static let horizontalInset: CGFloat = 6
    /// Separator band between groups (a hairline centered in it). inferred.
    static let separatorHeight: CGFloat = 12
    /// Row height: the six rows fill the observed 308 pt with the insets and separators above.
    /// inferred (derived from the observed size).
    static var rowHeight: CGFloat {
        let rows = CGFloat(SidebarNewMenuItem.allCases.count)
        let separators = CGFloat(SidebarNewMenuItem.groups.count - 1)
        return (size.height - 2 * verticalInset - separators * separatorHeight) / rows
    }
    /// Row highlight under the pointer: rounded, ink at this opacity. inferred.
    static let rowCornerRadius: CGFloat = 8
    static let rowHoverInkOpacity: Double = 0.08
    /// Icon cell and glyph size, gap to the title. inferred.
    static let iconCellWidth: CGFloat = 20
    static let iconGlyphSize: CGFloat = 14
    static let iconTitleGap: CGFloat = 10
    /// Title / key hint ink opacities on the panel ink. inferred ("gray" key hint observed).
    static let titleInkOpacity: Double = 0.85
    static let keyHintInkOpacity: Double = 0.4
    static let disabledInkOpacity: Double = 0.3
    /// Panel corner radius. unknown; like the Site Control Center bubble.
    static var cornerRadius: CGFloat { CGFloat(Metrics.SiteControls.cornerRadius) }

    /// The panel frame: its lower-left corner on the top-left of `plusButton`, kept inside
    /// `container` (the window content) with the bubbles' margin. [06 §23] observed placement; the
    /// clamp is inferred.
    static func menuFrame(plusButton: CGRect, container: CGRect) -> CGRect {
        let origin = CGPoint(x: plusButton.minX, y: plusButton.minY - gapAboveButton - size.height)
        let margin = CGFloat(Metrics.FloatingBubble.windowMargin)
        let bounds = container.insetBy(dx: margin, dy: margin)
        return CGRect(origin: FloatingBubbleLayout.clamp(origin, size: size, into: bounds), size: size)
    }
}

// MARK: - Actions

extension ShellModel {
    /// Whether a New menu row can run now (disabled rows are drawn dimmed).
    func canPerformNewMenuItem(_ item: SidebarNewMenuItem) -> Bool {
        switch item {
        case .newSpace: !isIncognito
        case .newFolder: !isIncognito && selectedSpaceID != nil
        case .newEasel: canCreateEasel
        // Inert: the Boost editor never opened in the reference ([06 §12] observed). Left enabled,
        // a click only closes the menu.
        case .newBoost: true
        case .newSplit: selectedTabID != nil
        case .newTab: true
        }
    }

    /// Runs a New menu row; each one does what its menu-bar command does. [06 §23] observed rows.
    func performNewMenuItem(_ item: SidebarNewMenuItem) {
        guard canPerformNewMenuItem(item) else { return }
        switch item {
        case .newSpace: spaceFlow.beginCreate()
        case .newFolder: sidebar.requestNewFolder()
        case .newEasel: newEasel()
        case .newBoost: break
        case .newSplit: addSplitView()
        case .newTab: presentCommandBar(.newTab)
        }
    }
}

/// The window whose New menu rows run (set by `MainWindowContent`); nil draws them disabled
/// (previews).
private struct SidebarNewMenuTargetKey: EnvironmentKey {
    static let defaultValue: ShellModel? = nil
}

extension EnvironmentValues {
    var sidebarNewMenuTarget: ShellModel? {
        get { self[SidebarNewMenuTargetKey.self] }
        set { self[SidebarNewMenuTargetKey.self] = newValue }
    }
}

// MARK: - Views

/// The menu body: three groups of rows with hairlines between them.
struct SidebarNewMenuView: View {
    let palette: ThemePalette
    let isEnabled: (SidebarNewMenuItem) -> Bool
    let onSelect: (SidebarNewMenuItem) -> Void

    private typealias L = SidebarNewMenuLayout

    var body: some View {
        let ink = palette.floatingPanelInk.swiftUI
        VStack(spacing: 0) {
            ForEach(Array(SidebarNewMenuItem.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(ink.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .frame(height: L.separatorHeight)
                }
                ForEach(group, id: \.self) { item in
                    SidebarNewMenuRow(item: item, ink: ink, isEnabled: isEnabled(item)) { onSelect(item) }
                }
            }
        }
        .padding(.vertical, L.verticalInset)
        .padding(.horizontal, L.horizontalInset)
        .frame(width: L.size.width, height: L.size.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.newMenu")
    }
}

private struct SidebarNewMenuRow: View {
    let item: SidebarNewMenuItem
    let ink: Color
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    private typealias L = SidebarNewMenuLayout

    var body: some View {
        Button(action: action) {
            HStack(spacing: L.iconTitleGap) {
                Image(systemName: item.symbol)
                    .font(.system(size: L.iconGlyphSize, weight: .medium))
                    .frame(width: L.iconCellWidth)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let hint = item.keyHint {
                    Text(hint)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(ink.opacity(isEnabled ? L.keyHintInkOpacity : L.disabledInkOpacity * 0.6))
                }
            }
            .foregroundStyle(ink.opacity(isEnabled ? L.titleInkOpacity : L.disabledInkOpacity))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: L.rowHeight, maxHeight: L.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: L.rowCornerRadius, style: .continuous)
                    .fill(ink.opacity(isHovering && isEnabled ? L.rowHoverInkOpacity : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }
}

/// Shows the New menu in a borderless child panel above the view it is attached to (the dock's
/// "+" button), while `content` is set. A press outside it (other than on the "+" itself, which
/// toggles it) or Escape calls `onDismiss`. Our own panel, like the floating bubbles (B42).
struct SidebarNewMenuPresenter: NSViewRepresentable {
    let content: AnyView?
    let palette: ThemePalette
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FloatingBubbleAnchor.AnchorView {
        let view = FloatingBubbleAnchor.AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] in coordinator?.schedule() }
        context.coordinator.anchor = view
        update(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: FloatingBubbleAnchor.AnchorView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.content = content
        coordinator.palette = palette
        coordinator.onDismiss = onDismiss
        coordinator.schedule()
    }

    static func dismantleNSView(_ nsView: FloatingBubbleAnchor.AnchorView, coordinator: Coordinator) {
        coordinator.content = nil
        coordinator.hide()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var content: AnyView?
        var palette: ThemePalette?
        var onDismiss: (() -> Void)?

        private var panel: FloatingBubblePanel?
        private var host: FloatingBubbleHostingView<AnyView>?
        private var effect: NSVisualEffectView?
        private var monitors: [Any] = []
        private var observers: [NSObjectProtocol] = []
        private var isScheduled = false

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

        func hide() {
            removeMonitors()
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }

        private func dismiss() {
            let onDismiss = onDismiss
            hide()
            onDismiss?()
        }

        private func apply() {
            guard let content, let palette, let anchor, let window = anchor.window, let contentView = window.contentView else {
                hide()
                return
            }
            let containerInWindow = contentView.convert(contentView.bounds, to: nil)
            let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
            let button = CGRect(x: anchorInWindow.minX - containerInWindow.minX, y: containerInWindow.maxY - anchorInWindow.maxY,
                                width: anchorInWindow.width, height: anchorInWindow.height)
            let frame = SidebarNewMenuLayout.menuFrame(plusButton: button, container: CGRect(origin: .zero, size: containerInWindow.size))
            let radius = SidebarNewMenuLayout.cornerRadius
            let chrome = FloatingBubbleChrome(size: frame.size, cornerRadius: radius, arrow: nil,
                                              tint: palette.floatingPanelBackground, isDark: palette.isDark) { content }

            let panel = self.panel ?? makePanel()
            host?.rootView = AnyView(chrome)
            panel.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
            let inWindow = CGRect(x: containerInWindow.minX + frame.minX, y: containerInWindow.maxY - frame.maxY,
                                  width: frame.width, height: frame.height)
            let screenFrame = window.convertToScreen(inWindow)
            if panel.frame != screenFrame {
                panel.setFrame(screenFrame, display: true)
                effect?.maskImage = FloatingBubbleController.maskImage(size: frame.size, cornerRadius: radius, arrow: nil)
            }
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            if !panel.isVisible { panel.orderFront(nil) }
            installMonitors(window: window)
        }

        private func makePanel() -> FloatingBubblePanel {
            let panel = FloatingBubblePanel(contentRect: .zero)
            // Translucent over what is behind it, like the floating bubbles ([07 §12] observed for
            // the bubbles; for this menu inferred).
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

        private func installMonitors(window: NSWindow) {
            guard monitors.isEmpty else { return }
            if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
                    if panel.frame.contains(location) || event.window === panel { return }
                    // The "+" button toggles the menu itself.
                    if let anchor = self.anchor, let anchorWindow = anchor.window,
                       anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(location) { return }
                    self.dismiss()
                }
                return event
            }) { monitors.append(down) }
            if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.panel?.isVisible == true, event.keyCode == 53 else { return false }
                    self.dismiss()
                    return true
                }
                return handled ? nil : event
            }) { monitors.append(key) }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
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
    }
}
