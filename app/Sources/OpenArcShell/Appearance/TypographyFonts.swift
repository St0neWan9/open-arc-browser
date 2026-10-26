import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Bridges the framework-free type scale (`OpenArcDesign.Typography`, [07 §3]) to SwiftUI and AppKit
// fonts. Every chrome text is the system font (SF Pro) with default tracking. [07 §3] observed.

extension FontWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    var appKit: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

extension TextStyle {
    /// The SwiftUI system font of this style.
    var font: Font { .system(size: CGFloat(size), weight: weight.swiftUI) }
    /// The AppKit system font of this style.
    var nsFont: NSFont { .systemFont(ofSize: CGFloat(size), weight: weight.appKit) }
    /// `ink` at this style's opacity (multiplied with the ink's own alpha).
    func color(_ ink: RGBAColor) -> Color { ink.swiftUI.opacity(opacity) }
}

extension View {
    /// Applies a type-scale style: font and, when given, the ink at the style's opacity.
    func textStyle(_ style: TextStyle, ink: RGBAColor? = nil) -> some View {
        font(style.font).foregroundStyle(ink.map { style.color($0) } ?? Color.primary)
    }
}

extension RGBAColor {
    /// AppKit color for a token color.
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// An invisible accessibility element that fills the view it is attached to (as a background), so
/// a text line or icon cell is reported with its layout box (for example the 18 pt line of a
/// 13 pt label, like an AppKit text field) instead of the glyphs' bounds. The visual content is
/// hidden from accessibility by `accessibilityBox`.
private struct AccessibilityBox: View {
    let label: String
    let identifier: String
    let traits: AccessibilityTraits

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Reports this view to accessibility as one element with this view's frame.
    func accessibilityBox(label: String, identifier: String, traits: AccessibilityTraits = .isStaticText) -> some View {
        accessibilityHidden(true)
            .background(AccessibilityBox(label: label, identifier: identifier, traits: traits))
    }
}
