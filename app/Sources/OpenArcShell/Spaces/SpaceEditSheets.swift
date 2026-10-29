import SwiftUI
import OpenArcModel
import OpenArcDesign

/// Draws a Space icon: an emoji, or an SF Symbol name (same convention as the sidebar's icon view).
struct SpaceIconGlyph: View {
    let icon: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        if let first = icon.unicodeScalars.first, !first.isASCII {
            Text(icon).font(.system(size: size * 0.9))
        } else {
            Image(systemName: icon).font(.system(size: size * 0.8)).foregroundStyle(tint)
        }
    }
}

/// Generic emoji and symbol picker, shared by the creation form and "Change Space Icon…".
struct SpaceIconGrid: View {
    /// Shows "Use Default Icon". Only useful when an icon is set.
    let showsReset: Bool
    /// Called with the chosen icon; nil resets to the default.
    let onChoose: (String?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(SpaceFlowLocalTokens.emoji, id: \.self) { emoji in
                    cell { Text(emoji).font(.system(size: 20)) }
                        .onTapGesture { onChoose(emoji) }
                }
            }
            Divider()
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(SpaceFlowLocalTokens.symbols, id: \.self) { name in
                    cell { Image(systemName: name).font(.system(size: 15)) }
                        .onTapGesture { onChoose(name) }
                        .accessibilityLabel(name)
                }
            }
            if showsReset {
                Button("Use Default Icon") { onChoose(nil) }.buttonStyle(.link).font(Typography.settingsBody.font)
            }
        }
        .padding(14)
        .accessibilityIdentifier("openarc.space.iconGrid")
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: 32, height: 32).contentShape(Rectangle())
    }
}

/// "Rename Space…" sheet: one field, Cancel [ESC] and Rename [↵]. The spec lists the menu items
/// but not their surface; this mirrors the New Folder card [06 §3, 07 §6]. inferred.
struct RenameSpaceSheet: View {
    @ObservedObject var flow: SpaceFlowModel
    let palette: ThemePalette

    var body: some View {
        let canRename = !flow.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ModalCard(size: Metrics.Dialog.newFolderSize, palette: palette) {
            Text("Rename Space")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .padding(.top, ModalCardTokens.titleTop)
            ModalCardTextField(placeholder: "Space name…", text: $flow.renameText, palette: palette,
                               identifier: "openarc.renameSpace.nameField") { flow.commitRename() }
                .padding(.top, ModalCardTokens.fieldGap)
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) { flow.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Rename", keyCap: "↵", role: .primary, palette: palette, isEnabled: canRename) { flow.commitRename() }
                    .keyboardShortcut(.defaultAction)
            })
        }
    }
}

/// "Change Space Icon…" card.
struct ChangeSpaceIconSheet: View {
    @ObservedObject var flow: SpaceFlowModel
    let currentIcon: String?
    let palette: ThemePalette

    var body: some View {
        IconPickerCard(title: "Change Space Icon", showsReset: currentIcon != nil, palette: palette,
                       onChoose: { flow.chooseIcon($0) }, onCancel: { flow.cancelChangeIcon() })
    }
}

/// The icon picker as a modal card: title, the icon grid and Cancel [ESC], on the sheet colors
/// ([07 §6] observed) with the sheet radius ([07 §12] observed). The spec does not show this
/// surface; its layout is ours (inferred).
struct IconPickerCard: View {
    let title: String
    let showsReset: Bool
    let palette: ThemePalette
    let onChoose: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        let size = SpaceFlowLocalTokens.iconSheetSize
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                SpaceIconGrid(showsReset: showsReset, onChoose: onChoose)
                    .foregroundStyle(palette.dialogInk.swiftUI)
            }
            .frame(width: CGFloat(size.width), height: CGFloat(size.height), alignment: .topLeading)
            ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .padding(.trailing, 14)
                .padding(.bottom, 14)
        }
        .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        .background(palette.dialogBackground.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(Metrics.Dialog.cornerRadius), style: .continuous))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}

/// Presents the rename and icon cards centered in the window over the dimmed window.
/// [07 §12] observed (Rename Space; the icon picker follows it, inferred). B91.
struct SpaceFlowSheets: ViewModifier {
    @ObservedObject var flow: SpaceFlowModel
    /// Icon of the Space whose icon picker is open. Only this, not the workspace: SwiftUI compares
    /// a modifier's stored values on every window update, and comparing a workspace of thousands
    /// of tabs cost milliseconds per update (B99 profile).
    let pickerSpaceIcon: String?
    let palette: ThemePalette

    func body(content: Content) -> some View {
        content
            .windowModal(id: "renameSpace", isPresented: flow.renamingSpaceID != nil, size: Metrics.Dialog.newFolderSize) {
                RenameSpaceSheet(flow: flow, palette: palette)
            }
            .windowModal(id: "changeSpaceIcon", isPresented: flow.iconPickerSpaceID != nil, size: SpaceFlowLocalTokens.iconSheetSize) {
                ChangeSpaceIconSheet(flow: flow, currentIcon: pickerSpaceIcon, palette: palette)
            }
    }
}
