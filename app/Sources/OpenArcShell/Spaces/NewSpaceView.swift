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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.controlFill.swiftUI))
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
        .popover(isPresented: $isThemePopoverShown, arrowEdge: .trailing) {
            // The bubble opens to the right of the row. [06 §2] observed. Edits go to the draft and
            // become the new Space's theme on "Create Space".
            ThemeEditorView(theme: $flow.draftTheme, systemAppearance: flow.systemAppearance)
                // Grows from the side of the row it opens next to. [07 §11] observed (spring). B40.
                .themeBubbleMotion(anchor: .leading)
        }
    }
}
