import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Surfaces behind the B77 context-menu items: the Change Icon… picker (the Space icon picker,
// reused), the Edit Pinned Page ▸ Edit… sheet (URL + title), the favorite unread badge and the
// system share picker for a tab's link. Spec: docs/arc-spec/05-surfaces.md §context menus;
// 06-flows.md §12, §20.2, §21.5.

/// What a row shows in its icon cell when the item has a custom icon: the emoji, or the SF Symbol
/// in the row ink (same convention as `Space.icon`).
struct SidebarCustomIconView: View {
    let icon: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        SpaceIconGlyph(icon: icon, size: size, tint: tint)
            .frame(width: size, height: size)
            .accessibilityIdentifier("openarc.sidebar.customIcon")
    }
}

/// Change Icon… on a tab, favorite, folder or split row: the Space icon grid in the same sheet
/// shape as "Change Space Icon…". The spec lists the item, not its surface; reusing our Space icon
/// picker is the plan's decision (B77). "Use Default Icon" puts the favicon / folder glyph back.
struct SidebarChangeIconSheet: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        let current = viewModel.iconPickerItemID.flatMap { viewModel.customIcon(of: $0) }
        IconPickerCard(title: "Change Icon", showsReset: current != nil, palette: viewModel.palette,
                       onChoose: { viewModel.chooseIcon($0) }, onCancel: { viewModel.cancelChangeIcon() })
            .accessibilityIdentifier("openarc.sidebar.changeIconSheet")
    }
}

/// Values of the Edit… sheet that the spec does not give ([06 §21.8]: the form was not captured).
enum PinnedPageEditorTokens {
    /// Height of the sheet: the New Folder card plus one more field row. inferred.
    static let size = Size2D(width: Metrics.Dialog.newFolderSize.width, height: 290)
    static let fieldGap: CGFloat = 10
}

/// Edit Pinned Page ▸ Edit…: the pinned URL and the title in the New Folder card style
/// ([07 §6] observed card), Cancel [ESC] / Save [↵]. The form is inferred ([06 §21.8] not captured).
struct PinnedPageEditorSheet: View {
    @ObservedObject var viewModel: SidebarViewModel
    @State private var urlText = ""
    @State private var title = ""

    var body: some View {
        let palette = viewModel.palette
        let canSave = SidebarViewModel.pinnedPageURL(from: urlText) != nil
        ModalCard(size: PinnedPageEditorTokens.size, palette: palette) {
            Text("Edit Pinned Page")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .padding(.top, ModalCardTokens.titleTop)
            ModalCardTextField(placeholder: "URL", text: $urlText, palette: palette,
                               identifier: "openarc.pinnedPage.urlField", onSubmit: save)
                .padding(.top, ModalCardTokens.fieldGap)
            ModalCardTextField(placeholder: "Title", text: $title, palette: palette,
                               identifier: "openarc.pinnedPage.titleField", onSubmit: save)
                .padding(.top, PinnedPageEditorTokens.fieldGap)
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) { viewModel.cancelEditPinnedPage() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Save", keyCap: "↵", role: .primary, palette: palette, isEnabled: canSave, action: save)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .onAppear {
            guard let id = viewModel.pinnedPageEditorTabID, let tab = viewModel.workspace.tabs[id] else { return }
            urlText = (tab.pinnedURL ?? tab.url)?.absoluteString ?? ""
            title = tab.displayTitle
        }
    }

    private func save() { viewModel.commitEditPinnedPage(urlText: urlText, title: title) }
}

/// Favorite ▸ Rename…: one field and Cancel [ESC] / Rename [↵] on the New Folder card
/// ([06 §3], [07 §6] observed card). A favorite tile shows only its icon ([06 §21.3] observed), so
/// there is no title to edit in place; the card is inferred (F5-1). A blank field puts the page
/// title back, like a tab row.
struct FavoriteRenameSheet: View {
    @ObservedObject var viewModel: SidebarViewModel
    @State private var title = ""

    var body: some View {
        let palette = viewModel.palette
        ModalCard(size: Metrics.Dialog.newFolderSize, palette: palette) {
            Text("Rename Favorite")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .padding(.top, ModalCardTokens.titleTop)
            ModalCardTextField(placeholder: "Title", text: $title, palette: palette,
                               identifier: "openarc.favoriteRename.titleField", onSubmit: save)
                .padding(.top, ModalCardTokens.fieldGap)
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) { viewModel.cancelFavoriteRename() }
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Rename", keyCap: "↵", role: .primary, palette: palette, action: save)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .onAppear {
            guard let id = viewModel.favoriteRenameTabID, let tab = viewModel.workspace.tabs[id] else { return }
            title = tab.displayTitle
        }
        .accessibilityIdentifier("openarc.favoriteRename")
    }

    private func save() { viewModel.commitFavoriteRename(text: title) }
}

/// The favorite's unread badge: a small count capsule at the tile's top-right corner while Show
/// Unread Badge is on and the page has unread items. Look inferred (plan B77): the spec only names
/// the menu item and the hover tip ([05 §context menus], [06 §12] observed).
struct FavoriteUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(UnreadBadge.label(count: count))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(Color(red: 0.95, green: 0.27, blue: 0.23)))
            .offset(x: 4, y: -4)
            .allowsHitTesting(false)
            .accessibilityLabel("\(count) unread")
            .accessibilityIdentifier("openarc.sidebar.favorite.unreadBadge")
    }
}

/// Shows the B77 share picker from the sidebar. Its Change Icon… and Edit… cards are window cards
/// (`SidebarWindowModals`, B91).
struct SidebarItemEditSheets: ViewModifier {
    @ObservedObject var viewModel: SidebarViewModel

    func body(content: Content) -> some View {
        content
            .background(SidebarSharePickerAnchor(viewModel: viewModel))
    }
}

/// Shows the system share picker for `SidebarViewModel.shareRequest`, anchored at the pointer
/// (the menu was opened there). [06 §20.2], [06 §21.5] observed ("系统分享服务"); the anchor is
/// inferred.
private struct SidebarSharePickerAnchor: NSViewRepresentable {
    @ObservedObject var viewModel: SidebarViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { ProbeView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewModel = viewModel
        guard let request = viewModel.shareRequest, coordinator.shownSerial != request.serial else { return }
        coordinator.shownSerial = request.serial
        // After this update pass: the picker runs a modal menu loop.
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                guard let view, let window = view.window, viewModel.shareRequest?.serial == request.serial else {
                    viewModel.finishShare(serial: request.serial)
                    return
                }
                coordinator.pending = request.serial
                let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let anchor = NSRect(x: point.x, y: point.y, width: 1, height: 1)
                let picker = NSSharingServicePicker(items: [request.url])
                picker.delegate = coordinator
                picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
            }
        }
    }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        weak var viewModel: SidebarViewModel?
        var shownSerial: Int?
        var pending: Int?

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let serial = pending else { return }
            pending = nil
            viewModel?.finishShare(serial: serial)
        }
    }
}
