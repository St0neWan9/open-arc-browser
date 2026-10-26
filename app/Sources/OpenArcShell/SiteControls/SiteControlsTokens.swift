import CoreGraphics
import OpenArcDesign

// Site Control Center constants the spec does not pin down. The width comes from
// `Metrics.SiteControls.popoverWidth` ([07 §12] observed 236). Fonts come from `Typography` (panel styles, [07 §3] unknown for this bubble).
// Each value below carries its evidence level (CLAUDE.md "Evidence levels").

enum SiteControlsLocalTokens {
    /// Bubble width. [07 §12] observed (236).
    static let width = CGFloat(Metrics.SiteControls.popoverWidth)
    /// Bubble corner radius. [07 §12] observed (20).
    static let cornerRadius = CGFloat(Metrics.SiteControls.cornerRadius)
    /// Inner padding of the bubble. unknown.
    static let padding: CGFloat = 12
    /// Vertical gap between the sections. unknown.
    static let sectionSpacing: CGFloat = 12
    /// Gap between the 4 square tool buttons. unknown (4 buttons fit 104 pt of content).
    static let toolSpacing: CGFloat = 4
    /// Corner radius of the square tool buttons. unknown.
    static let toolCornerRadius: CGFloat = 6
    /// Diameter of a settings row's round icon. [06 §12] observed round; size unknown.
    static let rowIconSize: CGFloat = 26
    /// Height of the "Secure" pill and the "⋯" button. unknown.
    static let footerHeight: CGFloat = 24
    /// Seconds "Copied" stays after Copy Link. inferred (not described in 06 §12).
    static let copiedFeedbackDuration: Double = 1.5
    /// Seconds between the pointer leaving and the bubble closing. inferred (06 §12 only says
    /// it disappears when the pointer moves away).
    static let pointerLeaveGrace: Double = 0.3
    /// An extension's action icon in the "Extensions" section: Chrome's toolbar size. inferred.
    static let extensionIconSize: CGFloat = 16
    /// Extension popup limits: Chromium's (25×25 to 800×600 points), the page sizes itself in
    /// between. inferred (the spec records no extension popup).
    static let extensionPopupMinimumSize: Double = 25
    static let extensionPopupMaximumWidth: Double = 800
    static let extensionPopupMaximumHeight: Double = 600
    /// Corner radius of the extension popup bubble: the Site Control Center's, since it opens
    /// from the same button. inferred.
    static let extensionPopupCornerRadius = CGFloat(Metrics.SiteControls.cornerRadius)
    /// Inset of the page inside its bubble, so the bubble's rounded corners do not clip it.
    /// inferred.
    static let extensionPopupInset: CGFloat = 8

    static func clampedExtensionPopupSize(width: Double, height: Double) -> (width: Double, height: Double) {
        (min(max(width, extensionPopupMinimumSize), extensionPopupMaximumWidth),
         min(max(height, extensionPopupMinimumSize), extensionPopupMaximumHeight))
    }
}
