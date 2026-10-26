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

/// "Change Space Icon…" sheet.
struct ChangeSpaceIconSheet: View {
    @ObservedObject var flow: SpaceFlowModel
    let currentIcon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Change Space Icon").textStyle(Typography.dialogTitle).padding(.horizontal, 14).padding(.top, 14)
            SpaceIconGrid(showsReset: currentIcon != nil) { flow.chooseIcon($0) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { flow.cancelChangeIcon() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: SpaceFlowLocalTokens.iconSheetSize.width, height: SpaceFlowLocalTokens.iconSheetSize.height)
    }
}

/// Presents the rename and icon sheets on the window content.
struct SpaceFlowSheets: ViewModifier {
    @ObservedObject var flow: SpaceFlowModel
    let workspace: WorkspaceState
    let palette: ThemePalette

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { flow.renamingSpaceID != nil },
                set: { if !$0 { flow.cancelRename() } }
            )) { RenameSpaceSheet(flow: flow, palette: palette) }
            .sheet(isPresented: Binding(
                get: { flow.iconPickerSpaceID != nil },
                set: { if !$0 { flow.cancelChangeIcon() } }
            )) {
                ChangeSpaceIconSheet(flow: flow, currentIcon: flow.iconPickerSpaceID.flatMap { workspace.spaces[$0]?.icon })
            }
    }
}
