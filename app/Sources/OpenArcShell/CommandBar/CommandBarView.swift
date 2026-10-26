import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// SwiftUI command bar. Sizes, radius, row heights and colors come from `OpenArcDesign`; the few
// values the design module lacks live in `CommandBarStyle` below with their evidence level.

/// Constants missing from `Metrics` / `ThemePalette` / `Typography`. Evidence levels as in CLAUDE.md.
enum CommandBarStyle {
    /// Field placeholder text. unknown (not recorded in the spec).
    static let placeholder = "Search or Enter URL…"
    /// Glyph point sizes that give the measured ink: input globe 13 × 13 ([07 §5] observed ink),
    /// row icons in a 16 pt box (ink ≈ 12–13 [07 §5] observed). SF Symbols are our own icons.
    static let inputIconPointSize: CGFloat = 13
    /// Box of the input icon: its measured ink (13 × 13 centered at panel (31.5, 31.5)). [07 §5] observed.
    static let inputIconInk: CGFloat = 13
    static let rowIconPointSize: CGFloat = 13
    /// ⓘ glyph inside the 26 pt button. unknown (ink not measured).
    static let infoGlyphPointSize: CGFloat = 15
    /// Arrow glyph inside the 24 pt box. unknown.
    static let arrowGlyphPointSize: CGFloat = 11
    /// Shortcut hint: right edge 13 pt from the row's right edge ([06 §16.2] observed, AX), i.e.
    /// 2 pt less than the 15 pt the row's trailing padding already gives.
    static let shortcutHintTrailing: CGFloat = -2
}

private extension RGBAColor {
    var commandBarColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// The command bar panel: input row plus result rows. Place it with `CommandBarLayout.panelFrame`.
/// [07 §5] observed geometry: input row 64 (globe at 31.5, field from 52.5, ⓘ 26 pt 20.5 from the
/// right), a 0.5 pt separator inset 12, rows from +68 at a 50 pt pitch inset 7.5; panel radius ≈ 11,
/// #F9F9F9 / #181818, a 0.5 pt outline and a large soft shadow; no dimming of the window.
public struct CommandBarView: View {
    @ObservedObject private var viewModel: CommandBarViewModel
    private let palette: ThemePalette

    public init(viewModel: CommandBarViewModel, palette: ThemePalette = ThemeDerivation.palette(for: nil)) {
        self.viewModel = viewModel
        self.palette = palette
    }

    private var layout: CommandBarLayout {
        CommandBarLayout(presentation: viewModel.presentation, resultCount: viewModel.results.count)
    }

    public var body: some View {
        let layout = self.layout
        let c = Metrics.CommandBar.self
        let shape = RoundedRectangle(cornerRadius: c.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            inputRow(layout: layout)
                .frame(height: c.inputRowHeight)
                .overlay(alignment: .bottom) {
                    palette.commandBarSeparator.commandBarColor
                        .frame(height: c.separatorThickness)
                        .padding(.horizontal, c.separatorInset)
                        .offset(y: -c.separatorThickness / 2)
                }
            if !viewModel.results.isEmpty {
                resultsList(layout: layout)
                    .frame(height: layout.resultsAreaHeight, alignment: .top)
            }
        }
        .frame(width: layout.panelWidth, height: layout.panelHeight, alignment: .top)
        .background(shape.fill(palette.commandBarBackground.commandBarColor))
        .clipShape(shape)
        .overlay(outline(shape))
        .shadow(color: .black.opacity(c.shadowOpacity), radius: c.shadowRadius / 2, x: 0, y: c.shadowOffsetY)
        .accessibilityElement(children: .contain)
    }

    /// Light: a 0.5 pt dark hairline on the outer edge; dark: a 0.5 pt light line inside. [07 §5] observed.
    @ViewBuilder
    private func outline(_ shape: RoundedRectangle) -> some View {
        let width = Metrics.CommandBar.outlineThickness
        if palette.isDark {
            shape.strokeBorder(palette.commandBarOutline.commandBarColor, lineWidth: width)
        } else {
            shape.stroke(palette.commandBarOutline.commandBarColor, lineWidth: width * 2)
                .mask(shape.inset(by: -width).stroke(lineWidth: width * 2))
        }
    }

    // MARK: Input row

    private func inputRow(layout: CommandBarLayout) -> some View {
        let c = Metrics.CommandBar.self
        let iconBox = CGFloat(c.inputFieldLeading - c.inputIconCenter) * 2
        return ZStack(alignment: .topLeading) {
            Image(systemName: "globe")
                .font(.system(size: CommandBarStyle.inputIconPointSize, weight: .medium))
                .foregroundStyle(palette.commandBarSecondaryText.commandBarColor)
                .frame(width: CommandBarStyle.inputIconInk, height: CommandBarStyle.inputIconInk)
                .accessibilityBox(label: "Search", identifier: "openarc.commandbar.icon", traits: .isImage)
                .frame(width: iconBox, height: iconBox)
                .offset(x: c.inputIconCenter - iconBox / 2, y: c.inputIconCenter - iconBox / 2)
            // AppKit-backed so the field takes keyboard focus as soon as the bar is in a window
            // (B26); keys (arrows, Tab, Return, Escape) are routed in `CommandBarTextField`.
            CommandBarTextField(viewModel: viewModel, style: fieldStyle)
                .frame(width: max(0, layout.panelWidth - c.inputFieldLeading - (c.infoButtonTrailing + c.infoButtonSize) - 10),
                       height: c.inputFieldHeight)
                .offset(x: c.inputFieldLeading, y: c.inputFieldTop)
            accessoryButton
                .frame(width: c.infoButtonSize, height: c.infoButtonSize)
                .offset(x: layout.panelWidth - c.infoButtonTrailing - c.infoButtonSize, y: c.infoButtonTop)
        }
        .frame(width: layout.panelWidth, height: c.inputRowHeight, alignment: .topLeading)
    }

    /// ⓘ in the main window, ✕ in Little Arc. [06 §6] observed; panes show ⓘ (inferred).
    /// [07 §5, §9] observed the 26 × 26 button.
    @ViewBuilder
    private var accessoryButton: some View {
        let size = Metrics.CommandBar.infoButtonSize
        if viewModel.presentation == .littleArc {
            Button {
                viewModel.handle(.escape)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.commandBarSecondaryText.commandBarColor)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.CommandBar.resultArrowBoxCornerRadius + 2, style: .continuous)
                            .fill(palette.commandBarAccessoryFill.commandBarColor)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        } else {
            Image(systemName: "info.circle")
                .font(.system(size: CommandBarStyle.infoGlyphPointSize))
                .foregroundStyle(palette.commandBarSecondaryText.commandBarColor)
                .frame(width: size, height: size)
                .accessibilityBox(label: "Information", identifier: "openarc.commandbar.info", traits: .isButton)
        }
    }

    private var fieldStyle: CommandBarTextFieldStyle {
        let input = palette.commandBarInputText.nsColor
        return CommandBarTextFieldStyle(
            font: Typography.commandBarInput.nsFont,
            textColor: input,
            placeholder: CommandBarStyle.placeholder,
            placeholderColor: palette.commandBarSecondaryText.nsColor
        )
    }

    // MARK: Results

    private func resultsList(layout: CommandBarLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        CommandBarRow(
                            result: result,
                            presentation: viewModel.presentation,
                            isSelected: index == viewModel.selectedIndex,
                            colors: CommandBarRowColors(palette: palette),
                            favicon: viewModel.faviconProvider?(result),
                            onClick: {
                                viewModel.select(index: index)
                                if let action = viewModel.activate(at: index) { viewModel.onAction?(action) }
                            }
                        )
                        .id(result.id)
                    }
                }
                .padding(.horizontal, CommandBarLayout.rowHorizontalInset)
                .padding(.top, Metrics.CommandBar.resultsTopGap)
            }
            .onChange(of: viewModel.selectedIndex) { _, newValue in
                guard viewModel.results.indices.contains(newValue) else { return }
                proxy.scrollTo(viewModel.results[newValue].id)
            }
        }
    }
}

/// The row colors taken from the palette. [07 §3, §5, §8] observed.
struct CommandBarRowColors {
    var text: Color
    var secondaryText: Color
    var selectedText: Color
    var selectionFill: Color
    var arrowBoxFill: Color

    init(palette: ThemePalette) {
        text = palette.commandBarText.commandBarColor
        secondaryText = palette.commandBarSecondaryText.commandBarColor
        selectedText = palette.commandBarSelectedText.commandBarColor
        selectionFill = palette.commandBarSelection.commandBarColor
        arrowBoxFill = palette.commandBarArrowBoxFill.commandBarColor
    }
}

// MARK: - Row

/// One result row: icon, title (+ "— subtitle"), trailing action text, arrow box.
/// [07 §5] observed: the row is 50 pt (fill 46, radius ≈ 5); icon 16 pt at +16, title 11 pt after
/// it, all text SF Medium 13; the action text ends 7 pt before the 24 pt arrow box, which is 15 pt
/// from the right. Selected: white text, a white arrow box with a theme-colored arrow; unselected:
/// a black 4 % box with a gray arrow.
struct CommandBarRow: View {
    let result: CommandBarResult
    let presentation: CommandBarPresentation
    let isSelected: Bool
    let colors: CommandBarRowColors
    /// The page's favicon for site rows (C9); nil draws the placeholder glyph.
    var favicon: Data? = nil
    let onClick: () -> Void

    var body: some View {
        let c = Metrics.CommandBar.self
        let text = isSelected ? colors.selectedText : colors.text
        let dimmed = isSelected ? colors.selectedText : colors.secondaryText
        HStack(spacing: 0) {
            icon(tint: isSelected ? colors.selectedText : colors.text)
                .padding(.trailing, c.resultIconTextGap)
            titleView(primary: text, secondary: dimmed)
            Spacer(minLength: 8)
            if let trailing = result.trailingLabel(for: presentation) {
                Text(trailing)
                    .font(Typography.commandBarActionLabel.font)
                    .foregroundStyle(dimmed)
                    .lineLimit(1)
                    .padding(.trailing, c.resultActionToArrowGap)
            }
            // [06 §16.2] observed: a command row shows its shortcut at the right end, where other
            // rows have the arrow box (the hint's right edge sits 13 pt from the row's edge, over
            // the box's place); so the hint replaces the box (inferred).
            if let hint = result.visibleShortcutHint(for: presentation) {
                Text(hint)
                    .font(Typography.commandBarActionLabel.font)
                    .foregroundStyle(dimmed)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, CommandBarStyle.shortcutHintTrailing)
            } else {
                arrowBox
            }
        }
        .padding(.leading, c.resultIconLeading)
        .padding(.trailing, c.resultArrowBoxTrailing)
        .frame(height: c.resultRowPitch)
        .background(
            RoundedRectangle(cornerRadius: c.resultRowCornerRadius, style: .continuous)
                .fill(isSelected ? colors.selectionFill : Color.clear)
                .padding(.vertical, (c.resultRowPitch - c.resultRowHeight) / 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Title — subtitle" (subtitle gray, middle-truncated). [06 §7] observed in Little Arc; [07 §3]
    /// observed the "— example.net" subtitle in the window bar too.
    @ViewBuilder
    private func titleView(primary: Color, secondary: Color) -> some View {
        if let subtitle = result.subtitle, !subtitle.isEmpty, subtitle != result.title {
            HStack(spacing: 4) {
                Text(result.title)
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("— \(subtitle)")
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Typography.commandBarRowTitle.font)
        } else {
            Text(result.title)
                .font(Typography.commandBarRowTitle.font)
                .foregroundStyle(primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The site's favicon when known (C9), else a placeholder glyph (SF Symbols). 16 × 16 box.
    /// [07 §5, §9] observed the box.
    @ViewBuilder
    private func icon(tint: Color) -> some View {
        let size = Metrics.CommandBar.resultIconSize
        if let image = SidebarFaviconView.image(favicon) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: CommandBarStyle.rowIconPointSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }

    private var symbolName: String {
        switch result.iconHint {
        case .site: return "globe"
        case .pinned: return "pin"
        case .archive: return "archivebox"
        case .command: return "command"
        case .space: return "square.stack"
        case .search: return "magnifyingglass"
        case .globe: return "network"
        }
    }

    private var arrowBox: some View {
        let c = Metrics.CommandBar.self
        return Image(systemName: "arrow.right")
            .font(.system(size: CommandBarStyle.arrowGlyphPointSize, weight: .semibold))
            .foregroundStyle(isSelected ? colors.selectionFill : colors.secondaryText)
            .frame(width: c.resultArrowBoxSize, height: c.resultArrowBoxSize)
            .background(
                RoundedRectangle(cornerRadius: c.resultArrowBoxCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.white : colors.arrowBoxFill)
            )
    }
}

// MARK: - Preview harness (FakeEngine)

/// Builds a view model backed by a workspace whose tabs were loaded through `FakeEngine`.
public enum CommandBarPreviewSupport {
    /// Creates demo content through `FakeEngine` so previews exercise the same path as the app.
    @MainActor
    public static func makeViewModel(
        mode: CommandBarMode = .newTab,
        presentation: CommandBarPresentation = .window,
        now: Date = Date()
    ) async -> CommandBarViewModel {
        let titles: [String: String] = [
            "swift.org": "Swift.org",
            "developer.apple.com": "Apple Developer Documentation",
            "news.example.com": "Example News",
            "github.com": "GitHub",
            "docs.example.org": "Example Docs",
        ]
        let engine = FakeEngine(titleProvider: { url in titles[url.host ?? ""] ?? (url.host ?? "New Tab") })
        var workspace = WorkspaceState.demo(now: now)
        guard let space = workspace.allLiveSpaces.first else {
            return CommandBarViewModel(sources: [], mode: mode, presentation: presentation)
        }
        var archivedID: UUID?
        for (index, host) in ["swift.org", "developer.apple.com", "news.example.com", "github.com", "docs.example.org"].enumerated() {
            guard let url = URL(string: "https://\(host)/"),
                  let tab = try? await engine.makeTab(TabConfiguration(profileID: space.profileID, initialURL: url)) else { continue }
            let state = await tab.currentState()
            let id = UUID()
            if let next = try? TreeOps.openTab(workspace, id: id, spaceID: space.id, url: state.url, title: state.title, now: now.addingTimeInterval(Double(-index) * 60)) {
                workspace = next
                if host == "docs.example.org" { archivedID = id }
            }
        }
        if let archivedID, let next = try? TreeOps.archiveTab(workspace, id: archivedID, now: now) { workspace = next }
        let snapshot = workspace
        let suggestions = CommandBarStaticSuggestionProvider(phrases: ["swift concurrency", "swiftui tutorials", "github actions"])
        let model = CommandBarViewModel(
            sources: commandBarDefaultSources(workspace: { snapshot }, suggestions: suggestions),
            mode: mode,
            presentation: presentation,
            currentSpaceID: space.id
        )
        model.open(mode: mode, currentSpaceID: space.id)
        await model.waitForRefresh()
        return model
    }
}

/// Loads the demo view model and shows the bar over a neutral backdrop (for previews).
public struct CommandBarPreviewHarness: View {
    private let mode: CommandBarMode
    private let presentation: CommandBarPresentation
    @State private var viewModel: CommandBarViewModel?

    public init(mode: CommandBarMode = .newTab, presentation: CommandBarPresentation = .window) {
        self.mode = mode
        self.presentation = presentation
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.55)
            if let viewModel {
                CommandBarView(viewModel: viewModel)
                    .padding(.top, 80)
            }
        }
        .frame(width: 900, height: 520)
        .task {
            if viewModel == nil { viewModel = await CommandBarPreviewSupport.makeViewModel(mode: mode, presentation: presentation) }
        }
    }
}

struct CommandBarView_Previews: PreviewProvider {
    static var previews: some View {
        CommandBarPreviewHarness(mode: .newTab)
            .previewDisplayName("New tab (empty query)")
        CommandBarPreviewHarness(mode: .newTab, presentation: .littleArc)
            .previewDisplayName("Little Arc")
    }
}
