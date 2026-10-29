import SwiftUI
import AppKit
import OpenArcDesign

// The Settings window's own look (B91). [07 §6] observed: 684 × 650, a 56 pt toolbar under the
// title bar, toggle rows 37 pt apart. Arc's window is a dark purple (≈ #241F29, [07 §6]
// observed), but the user rejected a dark Settings window (2026-10-28: "Settings must not be
// dark"; the toolbar pane icons were nearly invisible on it). So, as a user decision and not the
// spec, the window is always light: the aqua appearance and a light gray fill, whatever the
// system setting, with the system's own title bar and toolbar so the pane icons and labels read
// normally. The colors live in `ThemeDerivation`, the sizes in `Metrics.Settings`.

/// Window-wide look of the Settings panes: always light, the light fill behind every pane, no
/// system list or form backgrounds over it, toggle rows at the observed pitch.
struct SettingsWindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toggleStyle(SettingsToggleStyle())
            .scrollContentBackground(.hidden)
            .background(ThemeDerivation.settingsWindowBackground.swiftUI)
            .environment(\.colorScheme, .light)
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

/// Makes the Settings window light whatever the system appearance (user decision, 2026-10-28),
/// with the light fill and the system's opaque title bar and toolbar, so the toolbar's pane icons
/// and labels draw in their normal dark color. Writes only what differs.
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

    /// Light appearance, the light fill, the system title bar. Returns whether anything changed.
    /// Exposed for tests.
    @discardableResult
    @MainActor
    static func apply(to window: NSWindow) -> Bool {
        var changed = false
        if window.appearance?.name != .aqua { window.appearance = NSAppearance(named: .aqua); changed = true }
        let fill = ThemeDerivation.settingsWindowBackground
        let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha)
        if window.backgroundColor != color { window.backgroundColor = color; changed = true }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false; changed = true }
        return changed
    }
}
