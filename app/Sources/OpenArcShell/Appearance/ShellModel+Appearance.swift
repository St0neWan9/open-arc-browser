import Foundation
import OpenArcDesign

// Window palette and View ▸ Appearance for one browser window (plan B21).

extension ShellModel {
    /// The palette the window draws with: the selected Space's (Automatic follows the system), or
    /// the default light neutral theme while the Create Space view is up ([06 §1] observed "light").
    var windowPalette: ThemePalette {
        spaceFlow.isCreating ? ThemeDerivation.palette(for: nil, appearance: .light) : sidebar.palette
    }

    /// View ▸ Appearance ("Websites, Easels, and Notes will use:"). [01 §View] observed. Per device,
    /// shared by every window; pages update at once.
    public var webAppearance: WebAppearance {
        get { controller.webAppearance }
        set {
            objectWillChange.send()
            controller.webAppearance = newValue
        }
    }
}
