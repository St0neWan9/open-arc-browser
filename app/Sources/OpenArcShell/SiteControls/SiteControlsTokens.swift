import CoreGraphics
import OpenArcDesign

// Site Control Center constants. Observed sizes come from `Metrics.SiteControls` ([07 §12],
// [04 §网页工具栏 (E16)]); the rest are local. Fonts come from `Typography` (panel styles, [07 §3] unknown for this bubble).
// Each value below carries its evidence level (CLAUDE.md "Evidence levels").

enum SiteControlsLocalTokens {
    /// Bubble width. [07 §12] observed (236).
    static let width = CGFloat(Metrics.SiteControls.popoverWidth)
    /// Bubble corner radius. [07 §12] observed (20).
    static let cornerRadius = CGFloat(Metrics.SiteControls.cornerRadius)
    /// The URL box icons (copy link, site controls): one 30 × 30 box each, the site controls one at
    /// window x 234–264, y 49–79. [07 §12] observed (`Metrics.SiteControls.urlBoxButtonSize`).
    static let urlBoxButtonSize = CGFloat(Metrics.SiteControls.urlBoxButtonSize)
    /// Right edge of the site controls icon to the box's right edge (268 − 264). [07 §12] observed.
    static let urlBoxButtonTrailingInset = CGFloat(Metrics.SiteControls.urlBoxButtonTrailingInset)
    /// Copy link sits directly left of site controls. inferred (only the right icon was measured).
    static let urlBoxButtonSpacing: CGFloat = 0
    /// Glyph of the URL box icons. unknown (icons may differ, CLAUDE.md).
    static let urlBoxGlyphSize: CGFloat = 12
    /// Inner padding of the bubble on every side: the four 48 pt tool buttons at a 56 pt pitch
    /// span 216 of the 236 pt bubble, centered. inferred from [04 §网页工具栏 (E16)] observed sizes.
    /// (E16's "inset 13" is the 262 pt window around the 236 pt bubble, not this padding.)
    static let padding = (width - toolRowWidth) / 2
    /// Top tool buttons. [04 §网页工具栏 (E16)] observed 48 × 32 at a 56 pt pitch.
    static let toolButtonSize = CGSize(width: Metrics.SiteControls.toolButtonSize.width,
                                       height: Metrics.SiteControls.toolButtonSize.height)
    static let toolPitch = CGFloat(Metrics.SiteControls.toolButtonPitch)
    static var toolSpacing: CGFloat { toolPitch - toolButtonSize.width }
    static var toolRowWidth: CGFloat { 3 * toolPitch + toolButtonSize.width }
    /// Columns of the tool and extension grids (4 tools). [06 §12] observed.
    static let toolColumns = 4
    /// Corner radius of the tool buttons. unknown.
    static let toolCornerRadius: CGFloat = 8
    /// Vertical gap between the sections. inferred: with the heights below, one settings row gives
    /// the observed 254 pt bubble ([04 §网页工具栏 (E16)]) and two give ≈ 296 ([07 §12]).
    static let sectionSpacing: CGFloat = 20
    /// Section header line ("Extensions", "Settings") and its gap to the section. inferred.
    static let headerHeight: CGFloat = 14
    static let headerSpacing: CGFloat = 4
    /// One settings row (round icon, title, status). inferred: the second row of [07 §12]
    /// (≈ 296) over [04 §网页工具栏 (E16)] (254) adds 42.
    static let rowHeight: CGFloat = 42
    /// Diameter of a settings row's round icon. [06 §12] observed round; size unknown.
    static let rowIconSize: CGFloat = 26
    /// Height of the "Secure" pill and the "⋯" button (32 × 32). [06 §17.3] observed.
    static let footerHeight = CGFloat(Metrics.SiteControls.footerHeight)
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
