import SwiftUI

/// Gives the shell a way to open the Settings window (for the command bar's "Settings…" row).
/// Apply it to a view inside a scene, where `openSettings` is available (macOS 14).
struct SettingsOpenerInstaller: ViewModifier {
    let shell: ShellModel
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openSettings
            shell.openSettingsWindow = { open() }
        }
    }
}

extension View {
    func installsSettingsOpener(_ shell: ShellModel) -> some View {
        modifier(SettingsOpenerInstaller(shell: shell))
    }
}
