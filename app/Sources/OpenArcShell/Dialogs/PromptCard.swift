import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The Arc-style prompt card (B197): one window-modal card for every question the window asks
// that has no card of its own. [06 §41] observed on the extension install card: 450 pt wide,
// centered in the window over the dimmed window, the 62 pt icon row at (38, 38), a Bold 17 title
// that wraps (lines ≈ 24.5 pt apart), a gray body, and the save card's buttons ("Cancel" ESC,
// blue primary ↵) 28 pt from the right and 26.5 pt from the bottom ([06 §30] observed). Unlike
// the fixed New Folder / Delete Space cards ([07 §6]), its height follows its content; the gaps
// between the parts are from the same capture (inferred where a comment says so).

/// Layout values of the prompt card. Measured on the 2× capture of the extension install card
/// ([06 §41]); the capture gives positions, so the gaps are inferred.
enum PromptCardTokens {
    /// [06 §41] observed (450, like the other cards of [07 §6]).
    static let width: CGFloat = 450
    /// Title top without an icon row: the New Folder card's. unknown (`ModalCardTokens.titleTop`).
    static let titleTopWithoutHeader: CGFloat = ModalCardTokens.titleTop
    /// Title top below the icon row: 117, as Delete Space ([07 §6] observed; [06 §41] ≈ 117).
    static var titleGapBelowHeader: CGFloat { CGFloat(Metrics.Dialog.deleteTitleTop - Metrics.Dialog.appIconTop - Metrics.Dialog.appIconSize) }
    /// Extra space between wrapped title lines (21 pt lines, ≈ 24.5 pt apart). inferred (capture).
    static let titleLineSpacing: CGFloat = 3.5
    /// Title bottom to body top. inferred (capture ≈ 9).
    static let bodyGap: CGFloat = 9
    /// "It can:" bottom to the first bullet, and between bullets. inferred (capture ≈ 6.5).
    static let bulletGap: CGFloat = 6.5
    /// Bullet dot inset and text inset from the body's left edge. inferred (capture ≈ 6 / 24).
    static let bulletDotInset: CGFloat = 6
    static let bulletTextInset: CGFloat = 24
    /// Space above fields, choice lists and the checkbox. unknown.
    static let controlGap: CGFloat = 14
    /// Space between stacked text fields. unknown.
    static let fieldSpacing: CGFloat = 10
    /// Body bottom to the button row. inferred (capture ≈ 16).
    static let buttonRowGap: CGFloat = 16
    /// Text stops this far from the right edge (the title wraps before the button row's margin).
    /// inferred (capture: symmetric with the 38 pt left edge).
    static let textTrailing: CGFloat = 38
    /// The arrow between the app icon and the extension icon: 18 pt from each, ≈ 26 pt wide,
    /// #B9BDD3. [06 §41] observed; the dark color inferred.
    static let headerArrowSpacing: CGFloat = 18
    static let headerArrowWidth: CGFloat = 26
    static let headerArrowSize: CGFloat = 22
    static let headerArrowInk = RGBAColor(hex: 0xB9BDD3)
    static let headerArrowDarkInk = RGBAColor(hex: 0xFFFFFF, alpha: 0.35)
    /// Rows of a choice list (certificates, passkey methods). unknown.
    static let choiceRowCornerRadius: CGFloat = 8
    static let choiceListCornerRadius: CGFloat = 10
}

/// What sits in the card's icon row.
enum PromptCardHeader {
    /// The app's own icon (Delete Space, notices).
    case appIcon
    /// An SF Symbol in the save card's gray block ([06 §30] observed for the key).
    case symbol(String)
    /// App icon ← extension icon. [06 §41] observed. Without its icon the extension shows the
    /// puzzle piece block. inferred.
    case extensionInstall(NSImage?)
}

/// One button of the card's row, left to right.
struct PromptCardButtonItem {
    let title: String
    let role: PageSaveCardPlan.Role
    var isEnabled = true
    let action: () -> Void
}

/// The card: icon row, title, the caller's content, and the button row. The last `.primary`
/// button answers Return and the `.cancel` one Esc (`WindowModalKeys`); `onEscape` takes Esc
/// when no button has the cancel role.
struct PromptCard<Content: View>: View {
    let palette: ThemePalette
    let header: PromptCardHeader?
    let title: String
    let buttons: [PromptCardButtonItem]
    var onEscape: (() -> Void)? = nil
    /// Shown in the button row's left end (a progress spinner).
    var accessory: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let d = Metrics.Dialog.self
        let t = PromptCardTokens.self
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                PromptCardHeaderView(header: header, palette: palette)
                    .padding(.top, CGFloat(d.appIconTop))
            }
            Text(title)
                .textStyle(Typography.dialogTitle, ink: PromptCardInk.title(palette))
                .lineSpacing(t.titleLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, t.textTrailing - CGFloat(d.contentTrailing))
                .padding(.top, header == nil ? t.titleTopWithoutHeader : t.titleGapBelowHeader)
                .accessibilityAddTraits(.isHeader)
            content()
                .padding(.trailing, t.textTrailing - CGFloat(d.contentTrailing))
            buttonRow
                .padding(.top, t.buttonRowGap)
        }
        .padding(.leading, CGFloat(d.contentLeading))
        .padding(.trailing, CGFloat(d.contentTrailing))
        .padding(.bottom, CGFloat(d.contentBottom))
        .frame(width: t.width, alignment: .leading)
        .background(palette.dialogBackground.swiftUI)
        // Fully rounded, like every card of the family. [07 §12] observed (radius 26).
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(d.cornerRadius), style: .continuous))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }

    private var buttonRow: some View {
        // Plain buttons before the first keyed one sit at the left, the rest at the right.
        let split = buttons.firstIndex { $0.role != .plain } ?? buttons.count
        return HStack(spacing: PageSaveCardTokens.buttonSpacing) {
            if let accessory { accessory }
            ForEach(Array(buttons[..<split].enumerated()), id: \.offset) { _, item in button(item) }
            Spacer(minLength: 0)
            ForEach(Array(buttons[split...].enumerated()), id: \.offset) { _, item in button(item) }
            if let onEscape, !buttons.contains(where: { $0.role == .cancel }) {
                // Esc without a button of its own (the unresponsive page's Wait default).
                Button("", action: onEscape)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        // A left-hand button sits as far from the card's edge as the row on the right ([06 §30]
        // observed "Never on this site").
        .padding(.leading, split > 0 || accessory != nil ? CGFloat(Metrics.Dialog.contentTrailing - Metrics.Dialog.contentLeading) : 0)
    }

    @ViewBuilder
    private func button(_ item: PromptCardButtonItem) -> some View {
        let view = PageSaveCardButton(title: item.title, role: item.role, palette: palette, action: item.action)
            .disabled(!item.isEnabled)
            .opacity(item.isEnabled ? 1 : 0.5)
        switch item.role {
        case .plain: view
        case .cancel: view.keyboardShortcut(.cancelAction)
        case .primary: view.keyboardShortcut(.defaultAction)
        }
    }
}

/// Inks of the card's text, as the save card's ([06 §30] observed light values; dark inferred).
enum PromptCardInk {
    static func title(_ palette: ThemePalette) -> RGBAColor {
        palette.isDark ? palette.dialogInk : PageSaveCardTokens.titleInk
    }

    static func body(_ palette: ThemePalette) -> Color {
        palette.isDark ? Typography.dialogBody.color(palette.dialogInk) : PageSaveCardTokens.subtitleInk.swiftUI
    }
}

/// The card's body text: Regular 14, gray, wrapping.
struct PromptCardBodyText: View {
    let text: String
    let palette: ThemePalette

    var body: some View {
        Text(text)
            .font(Typography.dialogBody.font)
            .foregroundStyle(PromptCardInk.body(palette))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A bulleted list under the body ("It can:" ‧ permission). [06 §41] observed.
struct PromptCardBullets: View {
    let items: [String]
    let palette: ThemePalette

    var body: some View {
        let t = PromptCardTokens.self
        VStack(alignment: .leading, spacing: t.bulletGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("•")
                        .frame(width: t.bulletTextInset - t.bulletDotInset, alignment: .leading)
                        .padding(.leading, t.bulletDotInset)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typography.dialogBody.font)
                .foregroundStyle(PromptCardInk.body(palette))
            }
        }
    }
}

/// The checkbox under a card's body ("Always allow …"). Our look: unknown.
struct PromptCardCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    let palette: ThemePalette

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(Typography.dialogButton.font)
                .foregroundStyle(PromptCardInk.body(palette))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }
}

/// The icon row.
struct PromptCardHeaderView: View {
    let header: PromptCardHeader
    let palette: ThemePalette

    var body: some View {
        let t = PromptCardTokens.self
        switch header {
        case .appIcon:
            PromptCardAppIcon()
        case .symbol(let symbol):
            PromptCardSymbolBlock(symbol: symbol, palette: palette)
        case .extensionInstall(let icon):
            HStack(spacing: t.headerArrowSpacing) {
                PromptCardAppIcon()
                Image(systemName: "arrow.left")
                    .font(.system(size: t.headerArrowSize, weight: .regular))
                    .foregroundStyle((palette.isDark ? t.headerArrowDarkInk : t.headerArrowInk).swiftUI)
                    .frame(width: t.headerArrowWidth)
                    .accessibilityHidden(true)
                if let icon {
                    let side = CGFloat(Metrics.Dialog.appIconSize)
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .accessibilityHidden(true)
                } else {
                    PromptCardSymbolBlock(symbol: "puzzlepiece.extension.fill", palette: palette)
                }
            }
        }
    }
}

/// The app icon, 62 pt. [07 §6] observed (Delete Space).
struct PromptCardAppIcon: View {
    var body: some View {
        let side = CGFloat(Metrics.Dialog.appIconSize)
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// An SF Symbol in a 62 pt gray rounded block. [06 §30] observed (the save card's key).
struct PromptCardSymbolBlock: View {
    let symbol: String
    let palette: ThemePalette

    var body: some View {
        let t = PageSaveCardTokens.self
        let side = CGFloat(Metrics.Dialog.appIconSize)
        Image(systemName: symbol)
            .font(.system(size: t.iconGlyphSize))
            .foregroundStyle((palette.isDark ? palette.dialogInk : t.titleInk).swiftUI)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: t.iconBlockCornerRadius, style: .continuous)
                    .fill((palette.isDark ? t.iconBlockDarkFill : t.iconBlockFill).swiftUI)
            )
            .accessibilityHidden(true)
    }
}

/// Roles of a card's buttons, from their titles. The last button is the primary one (Return);
/// `cancelIndex` is the one Esc presses (nil: none, Esc gives the request's default); the
/// others are plain. Pure, for tests.
enum PromptCardRoles {
    static func roles(count: Int, cancelIndex: Int?) -> [PageSaveCardPlan.Role] {
        (0..<count).map { index in
            if index == count - 1 { return .primary }
            return index == cancelIndex ? .cancel : .plain
        }
    }
}
