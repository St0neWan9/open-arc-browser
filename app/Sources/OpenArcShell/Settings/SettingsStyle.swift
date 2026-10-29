import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The Settings window's look (B100): white window, near-white bordered cards in a centered
// column, small gray switches, borderless light-gray buttons and popups, colored icon tiles.
//
// Sources: [07 §6] (window 684 × 650, 56 pt toolbar, toggle rows 37 apart) and [07 §3] (body
// SF Regular 13). Everything else was measured on 2x captures of Arc's Settings window in light
// mode (B100 capture, observed: pixel distances halved; colors are JPEG samples, ±2/255 on flat
// areas, more on thin lines and text). The captured Arc window was inactive (gray traffic
// lights), so its switch and toolbar label colors are the inactive rendering.

/// Sizes of the Settings window's building blocks.
enum SettingsLayout {
    /// Left and right margin of the content column: cards span x 64…620 of the 684 pt window.
    /// B100 capture, observed.
    static let columnInset: CGFloat = 64
    /// Width of the content column (684 − 2 × 64). B100 capture, observed (556).
    static let columnWidth = SettingsTokens.windowWidth - 2 * columnInset
    /// Space between the toolbar hairline and the first card. B100 capture, observed (20).
    static let paneTopPadding: CGFloat = 20
    /// Space between two stacked cards. B100 capture, observed (8.5–10.5).
    static let cardSpacing: CGFloat = 9
    /// Card corner radius. B100 capture, observed (edge profile fits r 6).
    static let cardCornerRadius: CGFloat = 6
    /// Corner radius of the bordered list cards (profile list, shortcut list, icon list).
    /// B100 capture, observed (edge profile fits r 9 ±1).
    static let listCardCornerRadius: CGFloat = 9
    /// Card border width. B100 capture, observed (2 px at 2x).
    static let borderWidth: CGFloat = 1
    /// Leading and trailing inset of a row's content, and of the dividers between rows.
    /// B100 capture, observed (labels start 10 pt into the card; dividers 8–10 pt).
    static let rowInset: CGFloat = 10
    /// Divider between rows. B100 capture, observed (1 pt).
    static let dividerHeight: CGFloat = 1
    /// A switch row plus its divider repeats every 37 pt. [07 §6] observed.
    static let toggleRowPitch = CGFloat(Metrics.Settings.toggleRowPitch)
    /// Height of a switch row (pitch minus the divider). [07 §6] observed (37 pitch).
    static let toggleRowHeight = toggleRowPitch - dividerHeight
    /// Height of a row with a button or a popup. B100 capture, observed (43–44 pitch).
    static let controlRowHeight: CGFloat = 43
    /// Height of an Advanced row (icon tile, label, switch). B100 capture, observed (40 pitch).
    static let tileRowHeight: CGFloat = 39
    /// Height of a "Your Data and Settings" row (no dividers). B100 capture, observed (34 pitch).
    static let dataRowHeight: CGFloat = 34
    /// Space above and below the data rows inside their card. B100 capture, observed (5).
    static let dataCardVerticalPadding: CGFloat = 5
    /// Gap between an icon tile and its label. B100 capture, observed (≈ 9.5).
    static let tileLabelSpacing: CGFloat = 10
    /// Icon tile beside a "Your Data and Settings" row. B100 capture, observed (24).
    static let dataTileSize: CGFloat = 24
    /// Icon tile beside an Advanced row. B100 capture, observed (20).
    static let advancedTileSize: CGFloat = 20
    /// Tile corner radius as a share of its side. inferred (≈ 5 on 24, 4.5 on 20).
    static let tileCornerRatio: CGFloat = 0.22

    /// Switch. B100 capture, observed (36 × 16, a 21 × 14 knob).
    static let switchSize = CGSize(width: 36, height: 16)
    static let switchKnobSize = CGSize(width: 21, height: 14)

    /// Borderless filled button ("Previews Settings…" and the like). B100 capture, observed
    /// (24 tall, corner 5, text 12–13 pt from the edges).
    static let buttonHeight: CGFloat = 24
    static let buttonCornerRadius: CGFloat = 5
    static let buttonHorizontalPadding: CGFloat = 12
    /// Popup menu ("Google ⌃⌄"): same box as the button, at least 136 wide, the text 13 pt from
    /// the leading edge and the chevrons 10 pt from the trailing one. B100 capture, observed.
    static let popupMinWidth: CGFloat = 136
    static let popupLeadingPadding: CGFloat = 13
    static let popupTrailingPadding: CGFloat = 10
    /// Popups sit centered in a trailing column of this width. inferred (their centers line up
    /// at x 520 in the Profiles card; the widths vary with the text).
    static let popupColumnWidth: CGFloat = 180
}

/// Colors of the Settings window. B100 capture, observed unless noted.
enum SettingsPalette {
    /// Window, title bar and toolbar background.
    static let window = RGBAColor(hex: 0xFFFFFF)
    /// Hairline under the toolbar.
    static let toolbarHairline = RGBAColor(hex: 0xE8E8E8)
    /// Selected toolbar item's rounded highlight.
    static let toolbarSelection = RGBAColor(hex: 0xF9F9F9)
    /// Toolbar glyphs.
    static let toolbarGlyph = RGBAColor(hex: 0x7F7F7F)
    /// Toolbar labels in an inactive window: the selected item's is darker.
    static let toolbarLabel = RGBAColor(hex: 0xC3C3C3)
    static let toolbarSelectedLabel = RGBAColor(hex: 0x7C7C7C)
    /// The same in the key window. inferred (the system's secondary and primary label grays on
    /// white; the capture shows only the inactive window).
    static let toolbarLabelKey = RGBAColor(hex: 0x808080)
    static let toolbarSelectedLabelKey = RGBAColor(hex: 0x262626)
    /// Card fill and border.
    static let cardFill = RGBAColor(hex: 0xFDFDFD)
    static let cardBorder = RGBAColor(hex: 0xECECEC)
    /// Divider between rows.
    static let divider = RGBAColor(hex: 0xECECEC)
    /// Bordered list cards (profile list, shortcut list, icon list): white with a darker border.
    static let listCardFill = RGBAColor(hex: 0xFFFFFF)
    static let listCardBorder = RGBAColor(hex: 0xDFDFDF)
    /// Body text: row labels, paragraphs, button and popup text.
    static let bodyText = RGBAColor(hex: 0x4E4E4E)
    /// Strong text: icon names, the Custom Shortcuts title, shortcut list rows.
    static let strongText = RGBAColor(hex: 0x292929)
    /// Secondary text: subtitles, notes, the shortcut search placeholder.
    static let secondaryText = RGBAColor(hex: 0x9C9C9C)
    /// Small gray caption above a card ("Your Data and Settings").
    static let caption = RGBAColor(hex: 0xACACAC)
    /// List card header ("Your Profiles", "Default Shortcuts").
    static let listHeader = RGBAColor(hex: 0x9E9E9E)
    /// "CURRENT ICON" under the current icon's name.
    static let currentIconCaption = RGBAColor(hex: 0x979797)
    /// Inline link ("Learn more.").
    static let link = RGBAColor(hex: 0x5384D5)
    /// Popup chevrons and ⓘ glyphs.
    static let controlGlyph = RGBAColor(hex: 0x4F4F4F)
    /// The → arrow at the end of a data row.
    static let rowArrow = RGBAColor(hex: 0xAFAFAF)
    /// Button and popup fill: black at 5 % (#F0F0F0 on a card, #F2F2F2 on the window).
    static let buttonFill = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.05)
    /// Disabled button text.
    static let disabledText = RGBAColor(hex: 0xBCBCBC)
    /// Switch: off track, on track, knob and its rim.
    static let switchOffTrack = RGBAColor(hex: 0xEBEBEB)
    static let switchOnTrack = RGBAColor(hex: 0xE0E0E0)
    static let switchKnob = RGBAColor(hex: 0xFAFAFA)
    static let switchRim = RGBAColor(hex: 0xDFDFDF)
    /// Profile list row ("Default · 8 Spaces").
    static let profileRowFill = RGBAColor(hex: 0xF7F7F7)
    /// Icon list radio button: selected blue, unselected ring.
    static let radioSelected = RGBAColor(hex: 0x3950F4)
    static let radioRing = RGBAColor(hex: 0xCBCBCB)
    /// Shortcut key caps: white with a light border, gray text.
    static let keyCapBorder = RGBAColor(hex: 0xEEEEEE)
    static let keyCapText = RGBAColor(hex: 0x898989)
}

/// Text styles of the Settings window. Body 13 [07 §3] observed; the others: B100 capture,
/// observed (ink widths matched against SF at 2x).
enum SettingsFonts {
    static let body = Font.system(size: 13)
    static let toolbarLabel = Font.system(size: 11)
    static let listHeader = Font.system(size: 11, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let subtitle = Font.system(size: 11)
    static let note = Font.system(size: 12).italic()
    static let profileDetail = Font.system(size: 11)
    static let iconName = Font.system(size: 14, weight: .semibold)
    static let currentIcon = Font.system(size: 11, weight: .semibold)
    static let sideTitle = Font.system(size: 14, weight: .semibold)
    static let toolbarGlyph = Font.system(size: 19)
    static let chevron = Font.system(size: 10, weight: .semibold)
}

// MARK: - Cards and rows

/// A rounded card: near-white fill, 1 pt light border. Rows go inside, separated by
/// `SettingsDivider`.
struct SettingsCard<Content: View>: View {
    var style: Style = .grouped
    @ViewBuilder var content: Content

    enum Style {
        /// Toggle groups and control rows. B100 capture, observed.
        case grouped
        /// Bordered white lists (profiles, shortcuts, icons). B100 capture, observed.
        case list
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) { content }
            .background(shape.fill(fill.swiftUI))
            .clipShape(shape)
            .overlay(shape.strokeBorder(border.swiftUI, lineWidth: SettingsLayout.borderWidth))
    }

    private var radius: CGFloat {
        style == .grouped ? SettingsLayout.cardCornerRadius : SettingsLayout.listCardCornerRadius
    }
    private var fill: RGBAColor { style == .grouped ? SettingsPalette.cardFill : SettingsPalette.listCardFill }
    private var border: RGBAColor { style == .grouped ? SettingsPalette.cardBorder : SettingsPalette.listCardBorder }
}

/// Divider between two rows of a card, inset like the row content.
struct SettingsDivider: View {
    var leadingInset: CGFloat = SettingsLayout.rowInset

    var body: some View {
        Rectangle()
            .fill(SettingsPalette.divider.swiftUI)
            .frame(height: SettingsLayout.dividerHeight)
            .padding(.leading, leadingInset)
            .padding(.trailing, SettingsLayout.rowInset)
    }
}

/// One row of a card: content inset 10 pt, at least `height` tall.
struct SettingsRow<Content: View>: View {
    var height: CGFloat = SettingsLayout.toggleRowHeight
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .font(SettingsFonts.body)
            .foregroundStyle(SettingsPalette.bodyText.swiftUI)
            .padding(.horizontal, SettingsLayout.rowInset)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
    }
}

/// The leading part of a row: optional icon tile, the label with an optional ⓘ, an optional
/// gray subtitle (or italic note) under it.
struct SettingsRowLabel: View {
    let label: String
    var info: String?
    var subtitle: String?
    var subtitleIsNote = false
    var tile: SettingsTile?
    var maxLabelWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if let tile {
                SettingsTileView(tile: tile, size: SettingsLayout.advancedTileSize)
                    .padding(.trailing, SettingsLayout.tileLabelSpacing)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label).fixedSize(horizontal: false, vertical: true)
                    if let info { SettingsInfoGlyph(help: info) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleIsNote ? SettingsFonts.note : SettingsFonts.subtitle)
                        .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: maxLabelWidth, alignment: .leading)
        }
    }
}

/// A switch row: label (with optional tile, ⓘ, subtitle), the switch at the trailing edge.
/// [07 §6] observed: 37 pt pitch; a tiled row is 40 (B100 capture, observed).
struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var info: String?
    var subtitle: String?
    var subtitleIsNote = false
    var tile: SettingsTile?

    var body: some View {
        SettingsRow(height: tile == nil ? SettingsLayout.toggleRowHeight : SettingsLayout.tileRowHeight) {
            SettingsRowLabel(label: label, info: info, subtitle: subtitle, subtitleIsNote: subtitleIsNote, tile: tile)
            Spacer(minLength: 12)
            Toggle(isOn: $isOn) { Text(label) }
                .toggleStyle(SettingsSwitchStyle(showsLabel: false))
        }
        .padding(.vertical, subtitle == nil ? 0 : 6)
    }
}

/// A row with a label and a trailing control (button or popup). B100 capture, observed: 43 pt.
struct SettingsControlRow<Control: View>: View {
    let label: String
    var info: String?
    var subtitle: String?
    var tile: SettingsTile?
    /// A long label wraps before this width (General's Profile Settings hint). B100 capture,
    /// observed (wraps at ≈ 330 pt).
    var maxLabelWidth: CGFloat?
    @ViewBuilder var control: Control

    var body: some View {
        SettingsRow(height: tile == nil ? SettingsLayout.controlRowHeight : SettingsLayout.tileRowHeight) {
            SettingsRowLabel(label: label, info: info, subtitle: subtitle, tile: tile, maxLabelWidth: maxLabelWidth)
                .padding(.vertical, maxLabelWidth == nil && subtitle == nil ? 0 : 8)
            Spacer(minLength: 12)
            control
        }
    }
}

/// Small gray caption above a card ("Your Data and Settings", "iCloud").
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsFonts.caption)
            .foregroundStyle(SettingsPalette.caption.swiftUI)
            .padding(.leading, SettingsLayout.rowInset)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ⓘ next to a label; its text shows as a tooltip.
struct SettingsInfoGlyph: View {
    let help: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(SettingsFonts.body)
            .foregroundStyle(SettingsPalette.controlGlyph.swiftUI)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// A paragraph of body text in the column (Links, Profiles intro).
struct SettingsParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsFonts.body)
            .foregroundStyle(SettingsPalette.bodyText.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsLayout.rowInset)
    }
}

/// The content column of a pane: 64 pt from the window edges, 20 pt under the toolbar.
struct SettingsColumn<Content: View>: View {
    var spacing: CGFloat = SettingsLayout.cardSpacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(width: SettingsLayout.columnWidth, alignment: .topLeading)
            .padding(.top, SettingsLayout.paneTopPadding)
            .padding(.bottom, SettingsLayout.paneTopPadding)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A pane whose content may be taller than the window: the column scrolls.
struct SettingsScrollingPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Overlay scrollers only: a legacy scroll bar would take 15 pt from the right and push
        // the centered column off center.
        ScrollView(.vertical) { content }
            .scrollIndicators(.never)
    }
}

// MARK: - Controls

/// The small gray switch: 36 × 16, light track, a wide white knob. B100 capture, observed. A
/// click or Space flips it; it reads as a switch to VoiceOver.
struct SettingsSwitchStyle: ToggleStyle {
    /// False in a settings row, where the row draws the label itself.
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitch(configuration: configuration, showsLabel: showsLabel)
    }
}

private struct SettingsSwitch: View {
    let configuration: ToggleStyleConfiguration
    let showsLabel: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if showsLabel { configuration.label }
            SettingsSwitchShape(isOn: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The track and knob, without behavior. Exposed for tests (size).
struct SettingsSwitchShape: View {
    let isOn: Bool

    var body: some View {
        let size = SettingsLayout.switchSize
        let knob = SettingsLayout.switchKnobSize
        let inset = (size.height - knob.height) / 2
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill((isOn ? SettingsPalette.switchOnTrack : SettingsPalette.switchOffTrack).swiftUI)
            Capsule()
                .fill(SettingsPalette.switchKnob.swiftUI)
                .overlay(Capsule().strokeBorder(SettingsPalette.switchRim.swiftUI, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
                .frame(width: knob.width, height: knob.height)
                .padding(inset)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Borderless light-gray button. B100 capture, observed.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(SettingsFonts.body)
            .lineLimit(1)
            .foregroundStyle((isEnabled ? SettingsPalette.bodyText : SettingsPalette.disabledText).swiftUI)
            .padding(.horizontal, SettingsLayout.buttonHorizontalPadding)
            .frame(height: SettingsLayout.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.buttonCornerRadius, style: .continuous)
                    .fill(SettingsPalette.buttonFill.swiftUI)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.buttonCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0))
            )
            .opacity(isEnabled ? 1 : 0.7)
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.buttonCornerRadius, style: .continuous))
    }
}

/// One choice of a `SettingsPopup`.
struct SettingsOption<Value: Hashable>: Hashable {
    let value: Value
    let title: String
}

/// A popup menu drawn as Arc's: a light-gray filled box with the choice and ⌃⌄ chevrons.
/// The menu checks the current choice.
struct SettingsPopup<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [SettingsOption<Value>]
    var icon: (Value) -> NSImage? = { _ in nil }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    if let image = icon(option.value) {
                        Label { Text(option.title) } icon: { Image(nsImage: image) }.tag(option.value)
                    } else {
                        Text(option.title).tag(option.value)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            SettingsPopupLabel(title: title, image: icon(selection))
        }
        .menuStyle(.button)
        .buttonStyle(SettingsPopupButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }

    private var title: String { options.first { $0.value == selection }?.title ?? "" }
}

/// A popup with nothing to choose (a disabled row): the same box, one title.
struct SettingsStaticPopup: View {
    let title: String

    var body: some View {
        Button {} label: { SettingsPopupLabel(title: title, image: nil) }
            .buttonStyle(SettingsPopupButtonStyle())
            .fixedSize()
            .disabled(true)
    }
}

struct SettingsPopupLabel: View {
    let title: String
    let image: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            if let image {
                Image(nsImage: image).resizable().frame(width: 16, height: 16)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(SettingsFonts.chevron)
                .foregroundStyle(SettingsPalette.controlGlyph.swiftUI)
        }
        .frame(minWidth: SettingsLayout.popupMinWidth - SettingsLayout.popupLeadingPadding - SettingsLayout.popupTrailingPadding)
    }
}

private struct SettingsPopupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsPopupBody(configuration: configuration)
    }
}

private struct SettingsPopupBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(SettingsFonts.body)
            .foregroundStyle((isEnabled ? SettingsPalette.bodyText : SettingsPalette.disabledText).swiftUI)
            .padding(.leading, SettingsLayout.popupLeadingPadding)
            .padding(.trailing, SettingsLayout.popupTrailingPadding)
            .frame(height: SettingsLayout.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.buttonCornerRadius, style: .continuous)
                    .fill(SettingsPalette.buttonFill.swiftUI)
            )
            .contentShape(Rectangle())
    }
}

/// Centers a popup in the trailing popup column of a row.
struct SettingsPopupColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.frame(width: SettingsLayout.popupColumnWidth)
    }
}

// MARK: - Icon tiles

/// A colored rounded square with a white glyph, in front of a row. Glyphs are SF Symbols of our
/// choosing; tile colors are B100 capture, observed (Arc's) or ours where noted.
struct SettingsTile: Hashable, Sendable {
    let symbol: String
    let color: RGBAColor

    /// Tile colors. B100 capture, observed.
    static let blue = RGBAColor(hex: 0x4193F4)
    static let green = RGBAColor(hex: 0x66C56A)
    static let red = RGBAColor(hex: 0xEB5A4C)
    static let purple = RGBAColor(hex: 0xBF58D8)
    static let dataBlue = RGBAColor(hex: 0x64A2F6)
    static let dataGreen = RGBAColor(hex: 0x84CC86)
    static let dataYellow = RGBAColor(hex: 0xF7D870)
    static let dataOrange = RGBAColor(hex: 0xF7AA64)
    static let dataRed = RGBAColor(hex: 0xF3746E)
    /// Ours (rows Arc does not have): a neutral gray. inferred.
    static let gray = RGBAColor(hex: 0x9A9A9F)
    /// Ours (Autofill, a row the capture does not show): teal. inferred.
    static let dataTeal = RGBAColor(hex: 0x5BC2C6)
}

struct SettingsTileView: View {
    let tile: SettingsTile
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * SettingsLayout.tileCornerRatio, style: .continuous)
            .fill(tile.color.swiftUI)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: tile.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Key caps

/// A shortcut key cap: white, light border, gray symbols. B100 capture, observed (63.5 × 25
/// minimum, corner 5).
struct SettingsKeyCap: View {
    let keys: String

    static let minWidth: CGFloat = 63.5
    static let height: CGFloat = 25

    var body: some View {
        Text(keys)
            .font(SettingsFonts.body)
            .foregroundStyle(SettingsPalette.keyCapText.swiftUI)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: Self.minWidth, minHeight: Self.height)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(SettingsPalette.keyCapBorder.swiftUI, lineWidth: 1))
    }
}
