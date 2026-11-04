import SwiftUI
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The permission bubble. [06 §30] observed: from the URL box's site controls button with a small
// arrow, in the theme's near-white tint (#F4F2FF on the test Space), a gray circle with an SF icon at
// the left, gray body text at the right, and two equal buttons below. Our floating bubble draws it
// (FloatingBubble/), like the Site Control Center that opens from the same button. The light colors
// are observed; the dark ones inferred.

/// Local tokens of the bubble. Values marked "capture" were measured on the E36 captures; the spec
/// text does not give them, so they are inferred.
enum PermissionPromptTokens {
    /// Bubble width: the 262 pt window less its 13 pt inset on each side, as for the Site Control
    /// Center ([07 §12] observed). [06 §30] observed 262 × 145 for the window.
    static let width = SiteControlsLocalTokens.width
    /// inferred (capture, same as the Site Control Center's 20).
    static let cornerRadius = SiteControlsLocalTokens.cornerRadius
    /// Inset of the content from the bubble's edges. inferred (capture).
    static let padding: CGFloat = 10
    /// inferred (capture).
    static let iconDiameter: CGFloat = 32
    static let iconGlyphSize: CGFloat = 15
    /// Gray circle. inferred (capture: #DFDEED).
    static let iconFill = RGBAColor(hex: 0xDFDEED)
    /// inferred (capture).
    static let iconInk = RGBAColor(hex: 0x4B4B53)
    /// inferred.
    static let iconDarkFill = RGBAColor(hex: 0xFFFFFF, alpha: 0.12)
    /// Space between the circle and the text. inferred (capture).
    static let iconSpacing: CGFloat = 8.5
    /// The text's first line box sits this far below the circle's top. inferred (capture).
    static let textTopInset: CGFloat = 1
    /// Room right of the text: Arc wraps at about 160 pt ("Allow http://" stands alone on the first
    /// line). inferred (capture).
    static let textTrailingInset: CGFloat = 15
    /// Body text: ≈ #5D5D65, wraps, [06 §30] observed. Size: the spec gives ≈ 13 pt; the capture's ink
    /// widths fit 14 pt ("Allow http://" 76 pt wide) and lines 20 pt apart, so 14: inferred (capture).
    static let text = TextStyle(size: 14, weight: .regular)
    static let textInk = RGBAColor(hex: 0x5D5D65)
    /// Added to the font's own 17 pt line height for the 20 pt line pitch. inferred (capture).
    static let textLineSpacing: CGFloat = 3
    /// inferred.
    static let darkTextInk = RGBAColor(hex: 0xFFFFFF, alpha: 0.75)
    /// Space between the text and the buttons. inferred (capture).
    static let buttonsTop: CGFloat = 10
    /// inferred (capture: 216 × 32 for both, 9 apart).
    static let buttonHeight: CGFloat = 32
    static let buttonSpacing: CGFloat = 9
    static let buttonCornerRadius: CGFloat = 8
    /// inferred (capture: "Not Now" 56 pt wide).
    static let buttonText = TextStyle(size: 14, weight: .semibold)
    /// "Not Now". [06 §30] observed (≈ #DAD8E4).
    static let notNowFill = RGBAColor(hex: 0xDAD8E4)
    /// inferred.
    static let notNowDarkFill = RGBAColor(hex: 0xFFFFFF, alpha: 0.12)
    /// "Allow": white with a light rim. [06 §30] observed; the rim's color inferred (capture).
    static let allowRim = RGBAColor(hex: 0xB1B1B3)
    /// inferred.
    static let allowDarkFill = RGBAColor(hex: 0xFFFFFF, alpha: 0.22)
}

/// A permission request waiting in a tab's queue.
struct PendingPermissionPrompt {
    let center: DialogCenter
    let request: EngineDialogRequest

    var presentation: DialogPresentation { DialogPresentation(request) }

    /// Answers with button `index` of `DialogPresentation.buttons`.
    @MainActor
    func press(_ index: Int) {
        center.answer(request.id, with: DialogPresentation.answer(for: request, button: index, fieldValues: [], checkbox: false))
    }

    /// "Not Now", also what Esc presses. [06 §30] observed the button; Esc inferred.
    static let notNowIndex = 0
    static let allowIndex = 1
}

extension DialogCenter {
    /// The permission request `tabID` shows now, if its head is one.
    func permissionPrompt(for tabID: EngineTabID?) -> PendingPermissionPrompt? {
        guard let tabID, let request = current(for: tabID), DialogPresentation(request).style == .permissionBubble else { return nil }
        return PendingPermissionPrompt(center: self, request: request)
    }
}

/// Hands its content the permission request of the tab the window draws at a site controls button.
/// A view of its own so the view around it need not observe the dialog queues.
struct PermissionPromptReader<Content: View>: View {
    @ViewBuilder let content: (PendingPermissionPrompt?) -> Content
    @Environment(\.dialogCenter) private var center
    @Environment(\.windowDrawnPermissionTab) private var tabID

    var body: some View {
        if let center {
            Observed(center: center, tabID: tabID, content: content)
        } else {
            content(nil)
        }
    }

    private struct Observed: View {
        @ObservedObject var center: DialogCenter
        let tabID: EngineTabID?
        let content: (PendingPermissionPrompt?) -> Content

        var body: some View { content(center.permissionPrompt(for: tabID)) }
    }
}

extension View {
    /// Hangs the permission bubble from this view (a site controls button): below it, centered,
    /// arrow up, like the Site Control Center. `isHidden`: something else has that spot for now.
    func permissionPromptBubble(_ prompt: PendingPermissionPrompt?, palette: ThemePalette, isHidden: Bool = false) -> some View {
        floatingBubble(isPresented: prompt != nil && !isHidden) {
            permissionPromptBubbleRequest(prompt, palette: palette)
        }
    }
}

/// The bubble's request. It stays up until answered: a click on the page or in the sidebar must not
/// answer for the user, and a tab switch only hides it until the tab returns. inferred.
@MainActor
func permissionPromptBubbleRequest(_ prompt: PendingPermissionPrompt?, palette: ThemePalette) -> FloatingBubbleRequest {
    let t = PermissionPromptTokens.self
    return FloatingBubbleRequest(
        placement: .attached(.below),
        style: FloatingBubbleStyle(width: t.width, cornerRadius: t.cornerRadius,
                                   tint: palette.floatingPanelBackground, isDark: palette.isDark),
        content: AnyView(prompt.map { PermissionPromptView(prompt: $0, isDark: palette.isDark) }),
        onDismiss: { reason in
            if reason == .escape { prompt?.press(PendingPermissionPrompt.notNowIndex) }
        },
        waitsForAnswer: true
    )
}

/// The bubble's content: circle, text, Not Now and Allow.
struct PermissionPromptView: View {
    let prompt: PendingPermissionPrompt
    let isDark: Bool

    var body: some View {
        let t = PermissionPromptTokens.self
        let presentation = prompt.presentation
        VStack(alignment: .leading, spacing: t.buttonsTop) {
            HStack(alignment: .top, spacing: t.iconSpacing) {
                Image(systemName: presentation.symbol ?? "questionmark")
                    .font(.system(size: t.iconGlyphSize))
                    .foregroundStyle((isDark ? t.darkTextInk : t.iconInk).swiftUI)
                    .frame(width: t.iconDiameter, height: t.iconDiameter)
                    .background(Circle().fill((isDark ? t.iconDarkFill : t.iconFill).swiftUI))
                    .accessibilityHidden(true)
                Text(presentation.message)
                    .font(t.text.font)
                    .lineSpacing(t.textLineSpacing)
                    .foregroundStyle((isDark ? t.darkTextInk : t.textInk).swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, t.textTopInset)
                    .padding(.trailing, t.textTrailingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: t.buttonSpacing) {
                PermissionPromptButton(title: presentation.buttons[PendingPermissionPrompt.notNowIndex], isDark: isDark, isAllow: false) {
                    prompt.press(PendingPermissionPrompt.notNowIndex)
                }
                // Reaches the bubble drawn inside a panel; the floating panel never has the keyboard,
                // so `FloatingBubbleController` catches Esc for that one. Return presses nothing: a
                // grant is always a deliberate click. inferred.
                .keyboardShortcut(.cancelAction)
                PermissionPromptButton(title: presentation.buttons[PendingPermissionPrompt.allowIndex], isDark: isDark, isAllow: true) {
                    prompt.press(PendingPermissionPrompt.allowIndex)
                }
            }
        }
        .padding(t.padding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.dialog.permission")
    }
}

/// "Not Now" or "Allow": half the bubble's width each.
private struct PermissionPromptButton: View {
    let title: String
    let isDark: Bool
    let isAllow: Bool
    let action: () -> Void

    var body: some View {
        let t = PermissionPromptTokens.self
        let shape = RoundedRectangle(cornerRadius: t.buttonCornerRadius, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(t.buttonText.font)
                .foregroundStyle((isDark ? t.darkTextInk : t.textInk).swiftUI)
                .frame(maxWidth: .infinity)
                .frame(height: t.buttonHeight)
                .background(fill(shape))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fill(_ shape: RoundedRectangle) -> some View {
        let t = PermissionPromptTokens.self
        if isDark {
            shape.fill((isAllow ? t.allowDarkFill : t.notNowDarkFill).swiftUI)
        } else if isAllow {
            shape.fill(Color.white).overlay(shape.strokeBorder(t.allowRim.swiftUI, lineWidth: 0.5))
        } else {
            shape.fill(t.notNowFill.swiftUI)
        }
    }
}

/// The same bubble inside the tab's panel, at its top left, for a tab with no site controls button
/// to hang from. No arrow and no blur: it is drawn over the page. inferred.
struct PermissionPromptInPanel: View {
    let prompt: PendingPermissionPrompt
    let palette: ThemePalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PermissionPromptTokens.cornerRadius, style: .continuous)
        let b = Metrics.FloatingBubble.self
        PermissionPromptView(prompt: prompt, isDark: palette.isDark)
            .frame(width: PermissionPromptTokens.width)
            .background(shape.fill(palette.floatingPanelBackground.swiftUI))
            .overlay(shape.strokeBorder(Color.white.opacity(palette.isDark ? b.rimOpacityDark : b.rimOpacityLight),
                                        lineWidth: CGFloat(b.rimWidth)))
            .environment(\.colorScheme, palette.isDark ? .dark : .light)
            .padding(PermissionPromptPlacement.panelInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
