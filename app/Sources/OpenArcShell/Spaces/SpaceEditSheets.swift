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
                    .frame(maxWidth: .infinity)
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

/// Presents the rename card centered in the window over the dimmed window. [07 §12] observed. B91.
struct SpaceFlowSheets: ViewModifier {
    @ObservedObject var flow: SpaceFlowModel
    let palette: ThemePalette

    func body(content: Content) -> some View {
        content
            .windowModal(id: "renameSpace", isPresented: flow.renamingSpaceID != nil, size: Metrics.Dialog.newFolderSize) {
                RenameSpaceSheet(flow: flow, palette: palette)
            }
    }
}
