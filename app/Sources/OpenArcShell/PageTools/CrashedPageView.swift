import SwiftUI
import OpenArcModel
import OpenArcDesign

// The page's renderer died (`TabEvent.renderProcessGone`, C9). The spec records no crash page
// (unknown), so this is our own design: centered over the web panel, a glyph, a title and one line
// of explanation in the dialog type styles of [07] (`Typography.dialogTitle`, `.dialogBody`), and
// a Reload button that loads the page again in a new renderer.

/// What a crashed page's panel needs.
struct CrashedPageState {
    /// Reloads the tab (bringing up a new renderer).
    var reload: () -> Void
}

struct CrashedPageView: View {
    let state: CrashedPageState
    /// The panel color underneath (`ThemePalette.webPanelBackground`); picks the text ink.
    let panelColor: RGBAColor

    var body: some View {
        let whiteText = PlaceholderPage.usesWhiteText(on: panelColor)
        let ink = whiteText ? RGBAColor(hex: 0xFFFFFF) : RGBAColor(hex: 0x000000)
        VStack(spacing: CrashedPageTokens.spacing) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CrashedPageTokens.glyphSize, weight: .regular))
                .foregroundStyle(ink.swiftUI.opacity(CrashedPageTokens.glyphOpacity))
                .accessibilityHidden(true)
            Text(CrashedPageTokens.title)
                .textStyle(Typography.dialogTitle, ink: ink)
            Text(CrashedPageTokens.message)
                .textStyle(Typography.dialogBody, ink: ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: CrashedPageTokens.messageWidth)
            Button(CrashedPageTokens.reloadLabel, action: state.reload)
                .font(Typography.dialogButton.font)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("openarc.webPanel.crashed.reload")
        }
        .padding(CrashedPageTokens.spacing * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelColor.swiftUI)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.webPanel.crashed")
    }
}

/// Crash page constants. All our own (unknown in the spec).
enum CrashedPageTokens {
    static let title = "This page crashed"
    static let message = "Something went wrong while showing this page. Reload to try again."
    static let reloadLabel = "Reload"
    static let glyphSize: CGFloat = 34
    static let glyphOpacity = 0.55
    static let spacing: CGFloat = 12
    static let messageWidth: CGFloat = 320
}
