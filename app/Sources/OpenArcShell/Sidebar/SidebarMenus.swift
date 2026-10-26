import SwiftUI
import OpenArcModel
import OpenArcDesign

// Context menus. Item order and wording follow [05 §context menus] (observed) for pinned tabs,
// favorites and the Space background. Menus the spec did not read ("Today tab", folder, the
// Space "More" button, the "+" button) are inferred from the observed ones and marked below.
// Items that need a service outside the sidebar are forwarded as `SidebarRequest`s and stay
// disabled until the shell installs a handler.

enum SidebarTabMenuKind {
    case favorite
    case pinned
    /// Not observed ([05] "Today area tabs: not read"). Inferred: the pinned menu with
    /// "Pin Tab" / "Archive Tab" instead of the pin-specific items.
    case today
}

struct SidebarTabMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode
    let kind: SidebarTabMenuKind

    var body: some View {
        let id = tab.id
        let canRequest = viewModel.canRequest

        Button("Copy Link") {
            if let url = viewModel.linkURL(for: id) { SidebarPasteboard.copy(url) }
        }
        .disabled(viewModel.linkURL(for: id) == nil)

        Button("Share") { viewModel.requestFromMenu(.share(tabID: id)) }.disabled(!canRequest)

        if kind == .favorite {
            Button("Show Unread Badge") { viewModel.requestFromMenu(.toggleUnreadBadge(tabID: id)) }.disabled(!canRequest)
        }

        if kind != .today {
            Button("Change Icon…") { viewModel.requestFromMenu(.changeIcon(tabID: id)) }.disabled(!canRequest)
        }

        Button("Rename…") { viewModel.beginRename(id) }

        Button(viewModel.liveState(for: id)?.isMuted == true ? "Unmute" : "Mute") { viewModel.toggleMute(id) }
            .disabled(viewModel.liveState(for: id)?.isAudible != true)

        if kind != .today {
            Menu("Edit Pinned Page") {
                Button("Replace Pinned URL with Current") { viewModel.replacePinnedURLWithCurrent(id) }
                Button("Edit…") { viewModel.requestFromMenu(.editPinnedPage(tabID: id)) }.disabled(!canRequest)
            }
        }

        Button("Open in Split View") { viewModel.openInSplitView(id) }
        Button("Duplicate") { viewModel.duplicateTab(id) }

        SidebarMoveToMenu(viewModel: viewModel, tabID: id)

        Divider()
        switch kind {
        case .favorite:
            Button("Remove Favorite") { viewModel.removeFavorite(id) }
        case .pinned:
            Button("Remove Pin") { viewModel.unpinTab(id) }
        case .today:
            Button("Pin Tab") { viewModel.pinTab(id) }
            Button("Add to Favorites") { viewModel.addFavorite(id) }
            Button("Archive Tab") { viewModel.closeTab(id) }
        }
    }
}

/// Move to ▸ (Profile ▸ / each Space / New Space…). [05 §context menus] observed.
struct SidebarMoveToMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tabID: UUID

    var body: some View {
        Menu("Move to") {
            Menu("Profile") {
                ForEach(viewModel.workspace.profiles.values.sorted { $0.name < $1.name }, id: \.id) { profile in
                    Button(profile.name) { viewModel.requestFromMenu(.moveTab(tabID: tabID, toProfile: profile.id)) }
                        .disabled(!viewModel.canRequest)
                }
            }
            Divider()
            ForEach(viewModel.dockSpaces.filter { $0.id != viewModel.selectedSpaceID }, id: \.id) { space in
                Button(space.name) { viewModel.moveTab(tabID, toSpace: space.id) }
            }
            Divider()
            Button("New Space…") { viewModel.requestFromMenu(.newSpace) }.disabled(!viewModel.canRequest)
        }
    }
}

/// Space background menu. [05 §context menus] observed, in the observed order. The same content
/// is used for the Space "More" button (unobserved; inferred).
struct SidebarSpaceMenu: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        if let space = viewModel.selectedSpace {
            let canRequest = viewModel.canRequest
            Button("Change Space Icon…") { viewModel.requestFromMenu(.changeSpaceIcon(spaceID: space.id)) }.disabled(!canRequest)
            Button("Rename Space…") { viewModel.requestFromMenu(.renameSpace(spaceID: space.id)) }.disabled(!canRequest)
            Button("Edit Theme Color…") { viewModel.requestFromMenu(.editSpaceTheme(spaceID: space.id)) }.disabled(!canRequest)
            Menu("Set Profile") {
                ForEach(viewModel.workspace.profiles.values.sorted { $0.name < $1.name }, id: \.id) { profile in
                    Button(profile.name) { viewModel.requestFromMenu(.setSpaceProfile(spaceID: space.id, profileID: profile.id)) }
                        .disabled(!canRequest)
                }
                Divider()
                Button("New Profile…") {}.disabled(true)
            }
            Divider()
            Button("New Folder") { viewModel.requestNewFolder() }
            Menu("Live Folders") {
                Button("GitHub") { viewModel.requestFromMenu(.showLiveFolders(spaceID: space.id)) }.disabled(!canRequest)
            }
            Divider()
            Button("Share Space…") { viewModel.requestFromMenu(.shareSpace(spaceID: space.id)) }.disabled(!canRequest)
            Menu("Export “\(space.name)” into Folder") {
                ForEach(viewModel.dockSpaces.filter { $0.id != space.id }, id: \.id) { other in
                    Button(other.name) { viewModel.requestFromMenu(.exportSpace(spaceID: space.id, intoSpaceID: other.id)) }
                        .disabled(!canRequest)
                }
            }
            Divider()
            Button("Manage Spaces…") { viewModel.requestFromMenu(.manageSpaces) }.disabled(!canRequest)
            Button("Delete Space", role: .destructive) { viewModel.requestDeleteSpace(space.id) }
                .disabled(!viewModel.canDeleteSpace)
        }
    }
}

/// Folder menu. Not observed ([05] "folders: not read"); inferred from the tab menu and the
/// folder commands in [02 §tabs and sidebar].
struct SidebarFolderMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let folder: Folder

    var body: some View {
        Button("Rename Folder…") { viewModel.beginRename(folder.id) }
        Button(folder.isExpanded ? "Collapse Folder" : "Expand Folder") { viewModel.toggleFolder(folder.id) }
        Button("New Folder Inside…") { viewModel.requestNewFolder(parent: folder.id) }
        Divider()
        Button("Collapse All Folders") { viewModel.setAllFoldersExpanded(false) }
        Button("Expand All Folders") { viewModel.setAllFoldersExpanded(true) }
    }
}
