import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The Settings window's own look. [07 §6] observed: 684 × 650, a 56 pt toolbar under the title
// bar, toggle rows 37 apart. Arc's window measured in that pass was a dark purple, but the user
// rejected a dark Settings window (2026-10-28), and Arc's Settings in light mode is white (B100
// capture, observed): white title bar, toolbar and pane, a hairline under the toolbar. So the
// window is always light, whatever the system setting (user decision, B96), and draws the B100
// look: `SettingsPalette`, `SettingsLayout`.
//
// The toolbar is ours, not the system's: the system settings toolbar tints the selected pane
// with the accent color, while Arc's selection is a light gray rounded highlight with a darker
// label and gray outline glyphs (B100 capture, observed).

/// Window-wide look of the Settings panes: always light, white behind every pane, Arc's small
/// gray switches, the window title following the pane.
struct SettingsWindowChrome: ViewModifier {
    var title: String?

    func body(content: Content) -> some View {
        content
            .toggleStyle(SettingsSwitchStyle())
            .scrollContentBackground(.hidden)
            .background(SettingsPalette.window.swiftUI)
            .environment(\.colorScheme, .light)
            .background(SettingsWindowConfigurator(title: title))
    }
}

/// Makes the Settings window light whatever the system appearance (user decision, 2026-10-28),
/// with a white fill and the system's opaque title bar (no separator: the toolbar below draws its
/// own hairline), and sets the window title to the pane's. Writes only what differs.
struct SettingsWindowConfigurator: NSViewRepresentable {
    var title: String?

    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView(title: title) }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.title = title
        if let window = nsView.window { Self.apply(to: window, title: title) }
    }

    final class ConfiguratorView: NSView {
        var title: String?

        init(title: String?) {
            self.title = title
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindowConfigurator.apply(to: window, title: title)
        }
    }

    /// Light appearance, the white fill, a see-through title bar without a separator, the title.
    /// The title bar is transparent so the white fill shows behind the title, as in Arc
    /// (B100 capture, observed: #FFFFFF up to the top edge; an opaque system title bar paints its
    /// own #F6F6F8 band). Returns whether anything changed. Exposed for tests.
    @discardableResult
    @MainActor
    static func apply(to window: NSWindow, title: String? = nil) -> Bool {
        var changed = false
        if window.appearance?.name != .aqua { window.appearance = NSAppearance(named: .aqua); changed = true }
        let fill = SettingsPalette.window
        let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha)
        if window.backgroundColor != color { window.backgroundColor = color; changed = true }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true; changed = true }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none; changed = true }
        if let title, window.title != title { window.title = title; changed = true }
        return changed
    }
}

// MARK: - Toolbar

/// Geometry of the pane toolbar. B100 capture, observed unless noted.
enum SettingsToolbarLayout {
    /// The band under the title bar, hairline included. [07 §6] observed (56).
    static let height = CGFloat(Metrics.Settings.toolbarHeight)
    /// An item is its label plus 7 pt each side, at least 55 wide; items touch.
    static let itemPadding: CGFloat = 7
    static let itemMinWidth: CGFloat = 55
    /// Item (and selection highlight) height, from the top of the band.
    static let itemHeight: CGFloat = 48
    /// Corner radius of the selection highlight. B100 capture, observed (≈ 10).
    static let highlightCornerRadius: CGFloat = 10
    /// Glyph box height and the gap between glyph and label.
    static let glyphHeight: CGFloat = 24
    static let labelSpacing: CGFloat = 4

    /// Width of an item whose label is `labelWidth` wide.
    static func itemWidth(labelWidth: CGFloat) -> CGFloat {
        max(labelWidth + 2 * itemPadding, itemMinWidth)
    }

    /// Width of `title` in the toolbar label font (SF Regular 11, [07 §3] inferred).
    @MainActor
    static func labelWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(Typography.settingsToolbarLabel.size))
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The pane toolbar: gray outline glyphs over gray labels, the selected pane on a light gray
/// rounded highlight with a darker label. B100 capture, observed.
struct SettingsToolbar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsToolbarItem(pane: pane, isSelected: pane == selection) { selection = pane }
                }
            }
            .frame(height: SettingsToolbarLayout.itemHeight, alignment: .top)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Rectangle()
                .fill(SettingsPalette.toolbarHairline.swiftUI)
                .frame(height: 1)
        }
        .frame(height: SettingsToolbarLayout.height)
        .background(SettingsPalette.window.swiftUI)
    }
}

struct SettingsToolbarItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            VStack(spacing: SettingsToolbarLayout.labelSpacing) {
                Image(systemName: pane.systemImage)
                    .font(SettingsFonts.toolbarGlyph)
                    .foregroundStyle(SettingsPalette.toolbarGlyph.swiftUI)
                    .frame(height: SettingsToolbarLayout.glyphHeight)
                Text(pane.title)
                    .font(SettingsFonts.toolbarLabel)
                    .foregroundStyle(labelColor.swiftUI)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: SettingsToolbarLayout.itemWidth(labelWidth: SettingsToolbarLayout.labelWidth(pane.title)),
                   height: SettingsToolbarLayout.itemHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsToolbarLayout.highlightCornerRadius, style: .continuous)
                    .fill(isSelected ? SettingsPalette.toolbarSelection.swiftUI : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("openarc.settings.pane.\(pane.rawValue)")
    }

    /// Captured inactive: labels #C3C3C3, the selected one #7C7C7C (B100 capture, observed). In
    /// the key window the labels are darker (inferred: the system's secondary and primary label
    /// grays).
    private var labelColor: RGBAColor {
        let isKey = activeState == .key || activeState == .active
        switch (isSelected, isKey) {
        case (true, true): return SettingsPalette.toolbarSelectedLabelKey
        case (true, false): return SettingsPalette.toolbarSelectedLabel
        case (false, true): return SettingsPalette.toolbarLabelKey
        case (false, false): return SettingsPalette.toolbarLabel
        }
    }
}
