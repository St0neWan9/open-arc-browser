import SwiftUI
import AppKit
import OpenArcDesign

// The Settings window's own look (B91). [07 §6] observed: 684 × 650, a 56 pt toolbar under the
// title bar, toggle rows 37 pt apart, and a dark purple fill (≈ #241F29) that stays dark when the
// system is in light mode. The colors live in `ThemeDerivation`, the sizes in `Metrics.Settings`.

/// Window-wide look of the Settings panes: always dark, the purple fill behind every pane, no
/// system list or form backgrounds over it, toggle rows at the observed pitch.
struct SettingsWindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toggleStyle(SettingsToggleStyle())
            .scrollContentBackground(.hidden)
            .background(ThemeDerivation.settingsWindowBackground.swiftUI)
            .environment(\.colorScheme, .dark)
            .background(SettingsWindowConfigurator())
    }
}

/// A switch whose grouped-form row repeats every `Metrics.Settings.toggleRowPitch` points.
/// A grouped `Form` row adds `SettingsTokens.groupedRowChrome` above and below its content
/// (measured on ours: a 16 pt switch gives a 37.5 pt pitch), so the content is the pitch minus that.
struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .frame(height: SettingsTokens.toggleContentHeight)
    }
}

/// Makes the Settings window dark whatever the system appearance, with the purple fill under a
/// transparent title bar and toolbar. Writes only what differs.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        if let window = nsView.window { Self.apply(to: window) }
    }

    final class ConfiguratorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            SettingsWindowConfigurator.apply(to: window)
        }
    }

    /// Dark appearance, the purple fill, title bar drawn by the fill. Returns whether anything
    /// changed. Exposed for tests.
    @discardableResult
    @MainActor
    static func apply(to window: NSWindow) -> Bool {
        var changed = false
        let dark = NSAppearance(named: .darkAqua)
        if window.appearance?.name != .darkAqua { window.appearance = dark; changed = true }
        let fill = ThemeDerivation.settingsWindowBackground
        let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha)
        if window.backgroundColor != color { window.backgroundColor = color; changed = true }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true; changed = true }
        return changed
    }
}
