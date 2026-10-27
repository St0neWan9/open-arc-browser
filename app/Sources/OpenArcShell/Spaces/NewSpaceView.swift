import SwiftUI
import OpenArcModel
import OpenArcDesign

/// The creation view that replaces the sidebar. [06 §1] observed, top to bottom: illustration of
/// stacked cards, "Create a Space", the explanation, the name field with a dashed "+" icon button,
/// the Profile row, the "Choose a Theme" row, the primary "Create Space" button (disabled while the
/// name is empty) and a "Cancel" text button.
struct NewSpaceView: View {
    @ObservedObject var flow: SpaceFlowModel
    let palette: ThemePalette
    @Environment(\.windowSurface) private var surface

    @State private var isIconPopoverShown = false
    @State private var isThemePopoverShown = false
    @FocusState private var nameFocused: Bool

    private typealias T = SpaceFlowLocalTokens

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            illustration
            Text("Create a Space")
                .font(Typography.dialogTitle.font)
                .foregroundStyle(palette.primaryText.swiftUI)
            Text("Separate your tabs for life, work, projects, and more.")
                .font(Typography.settingsBody.font)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            nameField
            profileRow
            themeRow
            Button(action: { flow.create() }) {
                Text("Create Space")
                    .font(Typography.dialogButton.font.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: T.primaryButtonHeight)
                    .foregroundStyle(Color.white)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(flow.canCreate ? palette.primaryButtonFill.swiftUI : Color.gray.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!flow.canCreate)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("openarc.newSpace.create")
            Button("Cancel") { flow.cancelCreate() }
                .buttonStyle(.plain)
                .font(Typography.dialogButton.font)
                .foregroundStyle(palette.secondaryText.swiftUI)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("openarc.newSpace.cancel")
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { nameFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.newSpace")
    }

    /// Three stacked, slightly rotated cards. Our own drawing; icons and art may differ from Arc.
    private var illustration: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 64, height: 76)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .rotationEffect(.degrees(Double(index - 1) * 9))
                    .offset(x: CGFloat(index - 1) * 12)
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    private var nameField: some View {
        HStack(spacing: 8) {
            Button { isIconPopoverShown = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(palette.secondaryText.swiftUI)
                    if let icon = flow.draftIcon {
                        SpaceIconGlyph(icon: icon, size: 16, tint: palette.primaryText.swiftUI)
                    } else {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryText.swiftUI)
                    }
                }
                .frame(width: T.iconButtonSize, height: T.iconButtonSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose an icon")
            .accessibilityIdentifier("openarc.newSpace.iconButton")
            .popover(isPresented: $isIconPopoverShown, arrowEdge: .bottom) {
                SpaceIconGrid(showsReset: flow.draftIcon != nil) { icon in
                    flow.draftIcon = icon
                    isIconPopoverShown = false
                }
            }
            TextField("Space name…", text: $flow.draftName)
                .textFieldStyle(.plain)
                .font(Typography.addressField.font)
                .focused($nameFocused)
                .onSubmit { flow.create() }
                .accessibilityIdentifier("openarc.newSpace.nameField")
        }
        .padding(.horizontal, 8)
        .frame(width: T.contentWidth, height: T.fieldHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.windowFills(on: surface).controlFill.swiftUI))
    }

    private var profileRow: some View {
        HStack(spacing: 6) {
            Text("Profile").font(Typography.settingsBody.font).foregroundStyle(palette.secondaryText.swiftUI)
            Picker("Profile", selection: $flow.draftProfileID) {
                ForEach(flow.profiles, id: \.id) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            Image(systemName: "info.circle").font(.system(size: 12))
                .foregroundStyle(palette.secondaryText.swiftUI)
                .help("Each Profile has its own favorites and website data.")
        }
    }

    private var themeRow: some View {
        Button { isThemePopoverShown = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintbrush").font(.system(size: 12))
                Text("Choose a Theme").font(Typography.settingsBody.font)
                Circle().fill((flow.draftTheme.colors.first ?? T.defaultThemeColor).swiftUI)
                    .frame(width: 10, height: 10)
            }
            .foregroundStyle(palette.primaryText.swiftUI)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openarc.newSpace.theme")
        .frame(maxWidth: .infinity, alignment: .leading)
        // The bubble opens right of the row with an arrow pointing at it. [07 §12] observed: the
        // row spans x 14–262 of the 276 pt column and the bubble starts 13 pt right of it, centered
        // on it. The anchor reaches the observed row edge (our form is inset 28). Edits go to the
        // draft and become the new Space's theme on "Create Space".
        .background(Color.clear.floatingBubble(isPresented: isThemePopoverShown) {
            FloatingBubbleRequest(
                placement: .attached(.trailing),
                style: ThemeEditorView.bubbleStyle(for: flow.draftTheme, systemAppearance: flow.systemAppearance),
                content: AnyView(ThemeEditorView(theme: Binding(get: { flow.draftTheme }, set: { flow.draftTheme = $0 }),
                                                 systemAppearance: flow.systemAppearance, drawsBackground: false)),
                onDismiss: { _ in isThemePopoverShown = false }
            )
        }.padding(.trailing, -T.themeRowAnchorOutset))
    }
}

// MARK: - New empty Space illustration

/// When the faint illustration of a new, empty Space shows. [06 §1] observed: "创建后侧边栏用约
/// 0.3 秒淡入过渡,新 Space 空状态先显示一个淡色双手插画再消失".
enum NewSpaceIllustrationTrigger {
    /// The Space to show the illustration in when the creation view closes: the selected Space if
    /// "Create Space" made it (the selection moved away from the Space current when the view
    /// opened) and it is empty. Cancel leaves the selection, so nothing shows. inferred.
    static func spaceToGreet(startSpaceID: UUID?, selectedSpaceID: UUID?, isSelectedSpaceEmpty: Bool) -> UUID? {
        guard let selectedSpaceID, selectedSpaceID != startSpaceID, isSelectedSpaceEmpty else { return nil }
        return selectedSpaceID
    }

    /// Opacity while shown: faint. [06 §1] observed "淡色"; the value is inferred.
    static let opacity: Double = 0.18
    /// Seconds it stays before fading, and the fade. [06 §1] observed that it goes away; both
    /// durations are inferred (unknown in the capture).
    static let holdDuration: Double = 1.4
    static let fadeDuration: Double = 0.6
}

/// The faint illustration in the list area of a just-created, empty Space; it fades away on its
/// own. Our own art (open hands with sparkles from SF Symbols), not the reference's drawing.
struct NewSpaceIllustration: View {
    let tint: Color
    /// Called once it has faded out.
    let onFinished: () -> Void
    @State private var isShown = false

    private typealias N = NewSpaceIllustrationTrigger

    var body: some View {
        Image(systemName: "hands.sparkles")
            .font(.system(size: 54, weight: .light))
            .foregroundStyle(tint)
            .opacity(isShown ? N.opacity : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                // Fades in with the sidebar's create transition, then away. [06 §1] observed ≈ 0.3 s.
                withAnimation(ShellMotion.spaceCreateFade) { isShown = true }
                try? await Task.sleep(nanoseconds: UInt64((N.holdDuration) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(ShellMotion.newSpaceIllustrationFade) { isShown = false }
                try? await Task.sleep(nanoseconds: UInt64(N.fadeDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}
