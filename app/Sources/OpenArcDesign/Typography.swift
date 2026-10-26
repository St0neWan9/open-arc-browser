import Foundation

/// Font weight, independent of any UI framework. Shell maps it to SwiftUI / AppKit weights.
public enum FontWeight: String, Hashable, Sendable, CaseIterable {
    case regular, medium, semibold, bold
}

/// One text style: system font (SF Pro) at `size` and `weight`, default tracking, drawn in `color`
/// at `opacity`. `lineHeight` is the height of the text frame Arc reports for this size.
public struct TextStyle: Hashable, Sendable {
    public var size: Double
    public var weight: FontWeight
    /// Opacity of the text color (black / theme text / white, see `ThemePalette`). 1 = opaque.
    public var opacity: Double
    /// Text frame height. [07 §3] observed (13 → 18, 14 → 19, 17 → 21, 18 → 23); others inferred.
    public var lineHeight: Double

    public init(size: Double, weight: FontWeight = .regular, opacity: Double = 1, lineHeight: Double? = nil) {
        self.size = size
        self.weight = weight
        self.opacity = opacity
        self.lineHeight = lineHeight ?? Typography.lineHeight(forSize: size)
    }
}

/// The type scale. [07 §3] observed: every chrome text is the system font (SF Pro,
/// `.AppleSystemUIFont`) with the default tracking (no extra kern); no rounded or mono faces.
/// Sizes, weights and opacities per element below, each with its evidence level.
public enum Typography {
    /// AX text frame height for a font size. [07 §3] observed for 13, 14, 17, 18; other sizes
    /// interpolate (inferred: about 1.3 × size, rounded).
    public static func lineHeight(forSize size: Double) -> Double {
        switch size {
        case 13: return 18
        case 14: return 19
        case 17: return 21
        case 18: return 23
        default: return (size * 1.3).rounded()
        }
    }

    // MARK: Sidebar

    /// Address box text (domain and the "Search or Enter URL…" placeholder): Regular 13, black 60 %.
    /// [07 §3] observed (AX).
    public static let addressField = TextStyle(size: 13, weight: .regular, opacity: 0.60)
    /// The "Search or Enter URL…" placeholder renders at Medium 13: its ink matches SF Medium
    /// glyph by glyph (19 ink runs within 0.5 pt, span 134.5 vs 135; Regular spans 131.5 and
    /// merges "rc"). Round-2 comparison (B33) observed (PX, FIT); the AX font in [07 §3] is the
    /// field's (domain) font.
    public static let addressPlaceholder = TextStyle(size: 13, weight: .medium, opacity: 0.60)
    /// Space name: Semibold 13, black 45 %. [07 §3] observed (AX).
    public static let spaceName = TextStyle(size: 13, weight: .semibold, opacity: 0.45)
    /// Tab row title: Regular 14 in the theme's row text color. [07 §3] observed (AX).
    public static let tabRowTitle = TextStyle(size: 14, weight: .regular)
    /// Folder row title: Semibold 14 in the theme's row text color. [07 §3] observed (AX).
    public static let folderRowTitle = TextStyle(size: 14, weight: .semibold)
    /// "New Tab" row: Regular 14, black 30 %. [07 §3] observed (AX).
    public static let newTabRow = TextStyle(size: 14, weight: .regular, opacity: 0.30)
    /// Divider "Clear" button: not seen in E11 (hover only). [07 §3] unknown; Medium 11 at the
    /// space-name opacity is our placeholder.
    public static let dividerClear = TextStyle(size: 11, weight: .medium, opacity: 0.45)
    /// Hover card (title / hint): not triggerable in E11. [07 §3, §11] unknown; placeholder
    /// on the 13 pt chrome scale.
    public static let hoverCardTitle = TextStyle(size: 13, weight: .medium)
    public static let hoverCardHint = TextStyle(size: 11, weight: .regular, opacity: 0.5)

    // MARK: Command bar

    /// Input: Medium 18; light #101214 at 80 %, dark near white. [07 §3] observed (AX + PX).
    public static let commandBarInput = TextStyle(size: 18, weight: .medium, opacity: 0.80)
    /// Result title: Medium 13; light black 80 %, dark white ≈ 85 %, selected white. [07 §3] observed.
    public static let commandBarRowTitle = TextStyle(size: 13, weight: .medium, opacity: 0.80)
    /// Result subtitle ("— example.net"): Medium 13; light black 33 %, dark white ≈ 42 %. [07 §3] observed.
    public static let commandBarRowSubtitle = TextStyle(size: 13, weight: .medium, opacity: 0.33)
    /// Action text ("Switch to Tab"): Medium 13, like the subtitle; white when selected. [07 §3] observed.
    public static let commandBarActionLabel = TextStyle(size: 13, weight: .medium, opacity: 0.33)

    // MARK: Menus, sheets, settings

    /// Context menus: the system menu font, Regular 13. [07 §3] observed (FIT).
    public static let contextMenu = TextStyle(size: 13, weight: .regular)
    /// Sheet title (New Folder, Delete Space): Bold 17. [07 §3] observed (FIT).
    public static let dialogTitle = TextStyle(size: 17, weight: .bold)
    /// Sheet body text: Regular 14 (white ≈ 75 % on a dark sheet). [07 §3] observed (FIT).
    public static let dialogBody = TextStyle(size: 14, weight: .regular, opacity: 0.75, lineHeight: 17)
    /// Sheet text field and its placeholder: Regular 14. [07 §3] observed (FIT).
    public static let dialogTextField = TextStyle(size: 14, weight: .regular)
    /// Sheet buttons (Cancel / Create / Delete): Regular 13 (Medium 13 not excluded). [07 §3] inferred (FIT).
    public static let dialogButton = TextStyle(size: 13, weight: .regular)
    /// Key caps inside the sheet buttons (ESC, ↵): not measured. [07 §6] unknown; placeholder.
    public static let dialogKeyCap = TextStyle(size: 10, weight: .semibold)
    /// Settings body and toggle labels: Regular 13. [07 §3] observed (FIT).
    public static let settingsBody = TextStyle(size: 13, weight: .regular, lineHeight: 16)
    /// Settings secondary lines: one step below the body. [07 §3] inferred (system 11).
    public static let settingsCaption = TextStyle(size: 11, weight: .regular, opacity: 0.55)
    /// Settings toolbar labels: Regular 11. [07 §3] inferred (FIT).
    public static let settingsToolbarLabel = TextStyle(size: 11, weight: .regular)

    // MARK: Library

    /// Rail labels (Media, Boosts…): about 11, Semibold. [07 §3] inferred (FIT).
    public static let libraryRailLabel = TextStyle(size: 11, weight: .semibold)
    /// Empty-state title: 17, between Medium and Semibold. [07 §3] inferred (FIT).
    public static let libraryEmptyTitle = TextStyle(size: 17, weight: .medium, lineHeight: 20)
    /// Empty-state detail. [07 §3] unknown; the 13 pt body at 55 %.
    public static let libraryEmptyDetail = TextStyle(size: 13, weight: .regular, opacity: 0.55)
    /// Search field placeholder: about 14. [07 §3] inferred (FIT).
    public static let librarySearch = TextStyle(size: 14, weight: .regular, lineHeight: 17)
    /// Date group headers and list rows: not measured. [07 §3] unknown; on the sidebar scale.
    public static let libraryGroupHeader = TextStyle(size: 11, weight: .semibold, opacity: 0.55)
    public static let libraryRowTitle = TextStyle(size: 13, weight: .regular)
    public static let libraryRowDetail = TextStyle(size: 11, weight: .regular, opacity: 0.55)

    // MARK: Small floating panels (own look where Arc's was not measured)

    /// Section headers of small panels (Site Control Center "Extensions", "Settings"). [07 §3]
    /// unknown (hover not triggerable); on the 11 pt caption scale.
    public static let panelHeader = TextStyle(size: 11, weight: .semibold, opacity: 0.55)
    /// Row titles and status lines of small panels. [07 §3] unknown; 13 / 11 on the chrome scale.
    public static let panelRowTitle = TextStyle(size: 13, weight: .regular)
    public static let panelRowDetail = TextStyle(size: 11, weight: .regular, opacity: 0.55)
    /// Split pane bar domain pill. [07 §3] unknown; the address box style.
    public static let paneBarPill = TextStyle(size: 13, weight: .regular, opacity: 0.60)
    /// Onboarding (own design, D9): sheet title / body on the same scale.
    public static let onboardingTitle = TextStyle(size: 17, weight: .bold)
    public static let onboardingBody = TextStyle(size: 14, weight: .regular, opacity: 0.75)
    public static let onboardingCaption = TextStyle(size: 11, weight: .regular, opacity: 0.45)
}
