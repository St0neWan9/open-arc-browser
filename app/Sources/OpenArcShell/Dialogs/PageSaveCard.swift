import SwiftUI
import OpenArcEngine
import OpenArcModel
import OpenArcDesign

// The card a page's save offer shows: password save / update (C13) and the address / card offers
// (C30). [06 §30] observed for the password prompt: a window modal card (`.windowModal`, B91) of the
// same family as Delete Space, 450 × 273, centered in the window, with the same icon, title and body
// positions ([07 §6] observed). Its buttons differ from the other cards' fixed-size ones: they fit
// their text, the plain ones are white with a light rim and a thin lip under them, and the key caps
// are bigger. The light colors are [06 §30] observed; the dark ones inferred.

/// Local tokens of the save card. Sizes marked "capture" were measured on the E36 capture of the
/// card; the spec text does not give them, so they are inferred.
enum PageSaveCardTokens {
    /// Square behind the icon. [06 §30] observed (#E9E9F1, about 62 pt).
    static let iconBlockFill = RGBAColor(hex: 0xE9E9F1)
    /// inferred.
    static let iconBlockDarkFill = RGBAColor(hex: 0xFFFFFF, alpha: 0.10)
    /// inferred (capture).
    static let iconBlockCornerRadius: CGFloat = 14
    /// inferred (capture: the key is about 34 pt tall).
    static let iconGlyphSize: CGFloat = 30
    /// Title. [06 §30] observed (≈ #14151B).
    static let titleInk = RGBAColor(hex: 0x14151B)
    /// Subtitle. [06 §30] observed (≈ #505361).
    static let subtitleInk = RGBAColor(hex: 0x505361)
    /// Primary button. [06 §30] observed (≈ #3752F3).
    static let primaryFill = RGBAColor(hex: 0x3752F3)
    /// Key cap on the primary button: "a lighter blue frame". [06 §30] observed; the values inferred
    /// (capture).
    static let primaryKeyCapFill = RGBAColor(hex: 0xFFFFFF, alpha: 0.12)
    static let primaryKeyCapRim = RGBAColor(hex: 0xFFFFFF, alpha: 0.32)
    /// Gray key cap of the plain buttons. [06 §30] observed; the values inferred (capture).
    static let keyCapFill = RGBAColor(hex: 0xE8E8E8)
    static let keyCapInk = RGBAColor(hex: 0x737373)
    /// 1 pt rim and lip of the white buttons. [06 §30] observed; the color inferred (capture).
    static let plainButtonRim = RGBAColor(hex: 0xDBDBDB)
    /// Button height with its lip; the row's bottom margin is the other cards'. inferred (capture).
    static let buttonHeight: CGFloat = 37
    static let lipHeight: CGFloat = 1
    /// inferred (capture).
    static let buttonCornerRadius: CGFloat = 8
    /// Space between a button's edge and its text or key cap. inferred (capture).
    static let buttonPadding: CGFloat = 12
    /// Space between a button's title and its key cap, and between the No and Save buttons. inferred
    /// (capture).
    static let buttonSpacing: CGFloat = 8
    /// inferred (capture).
    static let keyCapHeight: CGFloat = 20
    static let keyCapCornerRadius: CGFloat = 5
    /// ESC: 35 wide, ↵: 29 wide. inferred (capture).
    static let escapeKeyCapWidth: CGFloat = 35
    static let returnKeyCapWidth: CGFloat = 29
    static let escapeKeyCapText = TextStyle(size: 11, weight: .bold)
    /// inferred (capture).
    static let returnGlyphSize: CGFloat = 12
    /// Text fits between the body's top and the buttons in the 273 pt card up to this many lines;
    /// a longer offer makes the card taller. inferred.
    static let linesInFixedHeight = 3
    /// Address offers run to name, street, city, email and phone. inferred.
    static let maximumLines = 6
}

/// The buttons and size of a card, from its presentation. No UI, for tests. The last button is the
/// primary one, the one before it answers Esc, and a third one sits alone at the left.
/// [06 §30] observed: "Never on this site" · "No" ESC · "Save" ↵.
struct PageSaveCardPlan: Equatable {
    enum Role: Equatable {
        /// White, at the left, no key.
        case plain
        /// White with the ESC cap: Esc presses it.
        case cancel
        /// Blue with the ↵ cap: Return presses it.
        case primary
    }

    struct Button: Equatable {
        let title: String
        /// Index in `DialogPresentation.buttons`.
        let index: Int
        let role: Role
    }

    let leading: Button?
    let trailing: [Button]
    let messageLines: [String]
    let size: Size2D

    init(_ presentation: DialogPresentation) {
        let titles = presentation.buttons
        let last = titles.count - 1
        leading = titles.count > 2 ? Button(title: titles[0], index: 0, role: .plain) : nil
        trailing = titles.indices.dropFirst(max(0, titles.count - 2)).map {
            Button(title: titles[$0], index: $0, role: $0 == last ? .primary : .cancel)
        }
        let lines = presentation.message.components(separatedBy: "\n")
        messageLines = Array(lines.prefix(PageSaveCardTokens.maximumLines))
        let base = Metrics.Dialog.deleteSpaceSize
        let extraLines = max(0, messageLines.count - PageSaveCardTokens.linesInFixedHeight)
        size = Size2D(width: base.width, height: base.height + Double(extraLines) * Typography.dialogBody.lineHeight)
    }
}

/// The card itself. The answers go through `DialogPresentation.answer`, like every other dialog.
struct PageSaveCard: View {
    let center: DialogCenter
    let request: EngineDialogRequest
    let presentation: DialogPresentation
    let palette: ThemePalette

    var body: some View {
        let d = Metrics.Dialog.self
        let t = PageSaveCardTokens.self
        let plan = PageSaveCardPlan(presentation)
        ModalCard(size: plan.size, palette: palette, buttonSpacing: t.buttonSpacing) {
            iconBlock
                .padding(.top, CGFloat(d.appIconTop))
            Text(presentation.title)
                .textStyle(Typography.dialogTitle, ink: palette.isDark ? palette.dialogInk : t.titleInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: CGFloat(Typography.dialogTitle.lineHeight))
                .padding(.top, CGFloat(d.deleteTitleTop - d.appIconTop - d.appIconSize))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.messageLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Typography.dialogBody.font)
                        .foregroundStyle(palette.isDark ? Typography.dialogBody.color(palette.dialogInk) : t.subtitleInk.swiftUI)
                        .lineLimit(1)
                        .frame(height: CGFloat(Typography.dialogBody.lineHeight))
                }
            }
            .padding(.top, CGFloat(d.deleteBodyTop - d.deleteTitleTop - Typography.dialogTitle.lineHeight))
        } buttons: {
            AnyView(ForEach(plan.trailing, id: \.index, content: button))
        } leadingButtons: {
            AnyView(plan.leading.map(button))
        }
        .accessibilityIdentifier("openarc.dialog.saveCard")
    }

    private var iconBlock: some View {
        let t = PageSaveCardTokens.self
        let side = CGFloat(Metrics.Dialog.appIconSize)
        return Image(systemName: presentation.symbol ?? "questionmark")
            .font(.system(size: t.iconGlyphSize))
            .foregroundStyle((palette.isDark ? palette.dialogInk : t.titleInk).swiftUI)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: t.iconBlockCornerRadius, style: .continuous)
                    .fill((palette.isDark ? t.iconBlockDarkFill : t.iconBlockFill).swiftUI)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func button(_ button: PageSaveCardPlan.Button) -> some View {
        let view = PageSaveCardButton(title: button.title, role: button.role, palette: palette) {
            let answer = DialogPresentation.answer(for: request, button: button.index, fieldValues: [], checkbox: false)
            center.answer(request.id, with: answer)
        }
        switch button.role {
        case .plain: view
        case .cancel: view.keyboardShortcut(.cancelAction)
        case .primary: view.keyboardShortcut(.defaultAction)
        }
    }
}

/// A button of the card, as wide as its title and key cap.
struct PageSaveCardButton: View {
    let title: String
    let role: PageSaveCardPlan.Role
    let palette: ThemePalette
    let action: () -> Void

    var body: some View {
        let t = PageSaveCardTokens.self
        Button(action: action) {
            HStack(spacing: t.buttonSpacing) {
                Text(title).textStyle(Typography.dialogButton, ink: titleInk)
                keyCap
            }
            .padding(.horizontal, t.buttonPadding)
            .frame(height: t.buttonHeight - (role == .primary ? 0 : t.lipHeight))
            .background(background)
            .padding(.bottom, role == .primary ? 0 : t.lipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var titleInk: RGBAColor {
        role == .primary ? RGBAColor(hex: 0xFFFFFF) : (palette.isDark ? palette.dialogInk : PageSaveCardTokens.titleInk)
    }

    @ViewBuilder
    private var keyCap: some View {
        let t = PageSaveCardTokens.self
        let shape = RoundedRectangle(cornerRadius: t.keyCapCornerRadius, style: .continuous)
        switch role {
        case .plain:
            EmptyView()
        case .cancel:
            Text("ESC")
                .font(t.escapeKeyCapText.font)
                .foregroundStyle(palette.isDark ? palette.dialogInk.swiftUI.opacity(0.6) : t.keyCapInk.swiftUI)
                .frame(width: t.escapeKeyCapWidth, height: t.keyCapHeight)
                .background(shape.fill(palette.isDark ? Color.white.opacity(0.12) : t.keyCapFill.swiftUI))
                .accessibilityHidden(true)
        case .primary:
            Image(systemName: "return")
                .font(.system(size: t.returnGlyphSize, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: t.returnKeyCapWidth, height: t.keyCapHeight)
                .background(shape.fill(t.primaryKeyCapFill.swiftUI))
                .overlay(shape.strokeBorder(t.primaryKeyCapRim.swiftUI, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var background: some View {
        let t = PageSaveCardTokens.self
        let shape = RoundedRectangle(cornerRadius: t.buttonCornerRadius, style: .continuous)
        if role == .primary {
            shape.fill((palette.isDark ? palette.dialogPrimaryButtonFill : t.primaryFill).swiftUI)
        } else if palette.isDark {
            shape.fill(palette.dialogSecondaryButtonFill.swiftUI)
        } else {
            shape.fill(Color.white)
                .overlay(shape.strokeBorder(t.plainButtonRim.swiftUI, lineWidth: 1))
                // The lip: the rim's color, hard-edged, one point below the button.
                .shadow(color: t.plainButtonRim.swiftUI, radius: 0, y: t.lipHeight)
        }
    }
}
