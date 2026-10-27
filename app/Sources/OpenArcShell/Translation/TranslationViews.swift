import SwiftUI
import AppKit
import OpenArcEngine
import OpenArcDesign

// Views of page translation (plan B47). Behavior: TranslationModel.swift. Spec: docs/arc-spec/
// 06-flows.md §19 (observed unless a token says otherwise).

/// Local look tokens. Each carries its evidence level.
enum TranslationLocalTokens {
    /// The URL box's second line: ≈ 11–12 pt in the domain's color. [06 §19.1] observed range;
    /// 12 inferred from the AX widths (122 for "Translation Available", 66 for "Translated").
    static let entryFontSize: CGFloat = 12
    /// Both lines share the 36 pt box, 17 pt each: domain at box y 0–17, the line at 17–34.
    /// [06 §19.1] observed (domain row moved up to the box top, the 17 pt tall line 17 below it).
    static let entryLineHeight: CGFloat = 17
    /// Bubble: the Site Control Center's chrome ([07 §12]), 236 wide. [06 §19.2] observed (content
    /// 236 × 102 / 100 inside a 262 pt window with 13 pt margins).
    static let bubbleWidth = CGFloat(Metrics.SiteControls.popoverWidth)
    static let bubbleCornerRadius = CGFloat(Metrics.SiteControls.cornerRadius)
    /// Inner padding: the two 104 pt buttons and their 7 pt gap leave 10.5 each side. [06 §19.2]
    /// observed sizes; the padding inferred from them.
    static let bubblePadding: CGFloat = 10.5
    /// The round "Aα" icon. [06 §19.2] observed 32 × 32.
    static let iconSize: CGFloat = 32
    /// Icon to title. inferred.
    static let iconTitleGap: CGFloat = 10
    /// Title row height (two lines of 13 pt). [06 §19.2] observed 126 × 34.
    static let titleMinHeight: CGFloat = 34
    static let titleFontSize: CGFloat = 13
    /// Title row to buttons: 102 − 2 × 10.5 − 34 − 32. inferred from the observed heights (also
    /// gives the observed 100 for the one-line "Translated from …" variant).
    static let rowGap: CGFloat = 15
    /// Buttons. [06 §19.2] observed 104 × 32, 7 apart; corner radius unknown.
    static let buttonSize = CGSize(width: 104, height: 32)
    static let buttonGap: CGFloat = 7
    static let buttonCornerRadius: CGFloat = 8
    /// "Options" sits one shade darker than the bubble. [06 §19.2] observed relation; amount unknown.
    static let secondaryButtonOpacity: Double = 0.10
    /// [06 §19.5] observed ≈ 3.6–4 s; middle of the range.
    static let revertNoticeDuration: Double = 3.8
    /// The ⌘Z key cap in the notice. [06 §19.5] observed 20 × 15.
    static let keyCapSize = CGSize(width: 20, height: 15)
    /// The notice's distance from the panel's top-right corner: the copy-link notice's. unknown
    /// ([06 §19.5] the look was not captured; inferred to be the same kind of pill as §17.3).
    static let noticeInset: CGFloat = WebToolbarLocalTokens.copiedToastInset
    /// The toolbar's "Translation Options" button glyph. Icons may differ (CLAUDE.md); [06 §19.1]
    /// observed a speech bubble with an "A".
    static let toolbarSymbol = "character.bubble"
    static let toolbarGlyphSize: CGFloat = 14
}

private struct TranslationModelKey: EnvironmentKey {
    static let defaultValue: TranslationModel? = nil
}

extension EnvironmentValues {
    /// The window's translation model. nil (previews, the bare sidebar) hides every entry.
    var translationModel: TranslationModel? {
        get { self[TranslationModelKey.self] }
        set { self[TranslationModelKey.self] = newValue }
    }
}

// MARK: - URL box line

/// "Translation Available" / "Translated" under the domain in the URL box; a click opens the
/// bubble below it. [06 §19.1, §19.2] observed.
struct TranslationURLBoxLine: View {
    @ObservedObject var model: TranslationModel
    let tabID: UUID?
    let ink: Color
    let palette: ThemePalette

    var body: some View {
        if let label = model.entryLabel(for: tabID) {
            Button { model.toggleBubble(for: tabID) } label: {
                Text(label.text)
                    .font(.system(size: TranslationLocalTokens.entryFontSize))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .frame(height: TranslationLocalTokens.entryLineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarUndimmedButtonStyle())
            .accessibilityLabel(label.text)
            .accessibilityIdentifier("openarc.sidebar.urlBox.translation")
            .translationBubble(model, tabID: tabID, palette: palette)
        }
    }
}

// MARK: - Toolbar button

/// "Translation Options" in the toolbar's right group, left of the Site Control Center button.
/// [06 §19.1] observed (32 × 24, pitch 36); the bubble opens below it.
struct TranslationToolbarButton: View {
    @ObservedObject var model: TranslationModel
    let tabID: UUID?
    let colors: WebToolbarColors
    let palette: ThemePalette

    var body: some View {
        WebToolbarButton(symbol: TranslationLocalTokens.toolbarSymbol, glyphSize: TranslationLocalTokens.toolbarGlyphSize,
                         label: "Translation Options", identifier: "openarc.webToolbar.translate", colors: colors) {
            model.toggleBubble(for: tabID)
        }
        .translationBubble(model, tabID: tabID, palette: palette)
    }
}

extension View {
    /// Anchors the translation bubble to this view: below it, centered, arrow up. [06 §19.2]
    /// observed (bubble under the entry, arrow at its top edge pointing at the text).
    func translationBubble(_ model: TranslationModel, tabID: UUID?, palette: ThemePalette) -> some View {
        floatingBubble(isPresented: model.isBubblePresented(for: tabID)) {
            FloatingBubbleRequest(
                placement: .attached(.below),
                style: FloatingBubbleStyle(width: TranslationLocalTokens.bubbleWidth, height: nil,
                                           cornerRadius: TranslationLocalTokens.bubbleCornerRadius,
                                           tint: palette.floatingPanelBackground, isDark: palette.isDark),
                content: AnyView(TranslationBubbleView(model: model, tabID: tabID, palette: palette)
                    .environment(\.colorScheme, palette.isDark ? .dark : .light)),
                onDismiss: { _ in model.closeBubble() }
            )
        }
    }
}

// MARK: - Bubble

/// "Translate this page to English?" [Options] [Translate], or "Translated from German."
/// [Options] [Use Original]. [06 §19.2, §19.4] observed.
struct TranslationBubbleView: View {
    @ObservedObject var model: TranslationModel
    let tabID: UUID?
    let palette: ThemePalette

    var body: some View {
        let t = TranslationLocalTokens.self
        let content = model.bubbleContent(for: tabID)
        VStack(alignment: .leading, spacing: t.rowGap) {
            HStack(alignment: .center, spacing: t.iconTitleGap) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(content?.title ?? "")
                        .font(.system(size: t.titleFontSize, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("openarc.translation.title")
                    if let note = content?.failureNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: content?.title.hasPrefix("Translated from") == true ? t.iconSize : t.titleMinHeight,
                       alignment: .leading)
                Spacer(minLength: 0)
            }
            HStack(spacing: t.buttonGap) {
                optionsMenu
                bubbleButton(content?.primaryButton ?? "Translate", isPrimary: true, id: "openarc.translation.primary") {
                    model.primaryAction(for: tabID)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(t.bubblePadding)
        .frame(width: t.bubbleWidth, alignment: .leading)
        .onExitCommand { model.closeBubble() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.translation.bubble")
    }

    /// The round, light "Aα" icon. [06 §19.2] observed (32 × 32, light round fill); glyph ours.
    private var icon: some View {
        Text("Aα")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: TranslationLocalTokens.iconSize, height: TranslationLocalTokens.iconSize)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }

    private func bubbleButton(_ title: String, isPrimary: Bool, id: String, action: @escaping () -> Void) -> some View {
        let t = TranslationLocalTokens.self
        return Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? Color.white : Color.primary)
                .frame(width: t.buttonSize.width, height: t.buttonSize.height)
                .background(
                    RoundedRectangle(cornerRadius: t.buttonCornerRadius, style: .continuous)
                        .fill(isPrimary ? palette.commandBarSelection.swiftUI : Color.primary.opacity(t.secondaryButtonOpacity))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// "Options": a native menu ([06 §19.3] observed items). SwiftUI's `Menu` opens it from the
    /// button (Arc opens it at the pointer; inside the bubble the two places nearly coincide).
    private var optionsMenu: some View {
        let t = TranslationLocalTokens.self
        return Menu {
            if let tabID {
                Menu(TranslationOptionsMenu.chooseLanguageTitle) {
                    ForEach(model.targetLanguages, id: \.code) { language in
                        Button(language.name) { model.translate(tabID, to: language.code) }
                    }
                }
                .disabled(model.targetLanguages.isEmpty)
                Button(TranslationOptionsMenu.neverTranslateTitle) { model.neverTranslateSite(tabID) }
                Divider()
                Button(TranslationOptionsMenu.languageSettingsTitle) { model.openLanguageSettings() }
            }
        } label: {
            Text("Options")
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .frame(width: t.buttonSize.width, height: t.buttonSize.height)
                .background(
                    RoundedRectangle(cornerRadius: t.buttonCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(t.secondaryButtonOpacity))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("openarc.translation.options")
    }
}

// MARK: - Options menu

/// [06 §19.3] observed items: Choose Another Language ▸ (every target language, alphabetical, no
/// check mark), Never Translate This Site, —, Language Settings.
enum TranslationOptionsMenu {
    static let chooseLanguageTitle = "Choose Another Language"
    static let neverTranslateTitle = "Never Translate This Site"
    static let languageSettingsTitle = "Language Settings"

    /// Top-level titles in order; "" is the separator.
    static let titles = [chooseLanguageTitle, neverTranslateTitle, "", languageSettingsTitle]
}

// MARK: - Revert notice

/// "Translated back to German! Use ⌘Z to undo." at the web panel's top right. [06 §19.5] observed
/// text, place and timing; the pill look is inferred from the copy-link notice (§17.3).
struct TranslationRevertNoticeView: View {
    @ObservedObject var model: TranslationModel
    let palette: ThemePalette

    var body: some View {
        if let notice = model.revertNotice {
            HStack(spacing: 5) {
                Text(notice.leadingText)
                Text("⌘Z")
                    .font(Typography.dialogKeyCap.font)
                    .frame(width: TranslationLocalTokens.keyCapSize.width, height: TranslationLocalTokens.keyCapSize.height)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.25)))
                Text(notice.trailingText)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(palette.commandBarSelection.swiftUI))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .transition(.opacity)
            .background(UndoKeyMonitor { model.undoRevert() })
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("openarc.translation.revertNotice")
        }
    }
}

/// ⌘Z while the notice shows translates again ([06 §19.5] observed), ahead of the page's own undo.
private struct UndoKeyMonitor: NSViewRepresentable {
    let onUndo: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onUndo)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUndo = onUndo
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var onUndo: (@MainActor () -> Bool)?
        private var monitor: Any?

        func install(_ handler: @escaping @MainActor () -> Bool) {
            onUndo = handler
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isUndo = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                    && event.charactersIgnoringModifiers?.lowercased() == "z"
                guard isUndo else { return event }
                let handled = MainActor.assumeIsolated { self?.onUndo?() ?? false }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
