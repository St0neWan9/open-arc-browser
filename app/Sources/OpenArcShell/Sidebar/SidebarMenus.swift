import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Context menus. Items, order, separators and disabled states follow [06 §21.5] (E19, observed
// by AX) for favorites, Today tabs, folders, split rows and the Space background; the pinned tab
// menu follows [05 §context menus] (observed items, separators inferred like the favorite menu).
// The incognito tab menu lives in `IncognitoSidebar.swift` ([06 §20.2]).
//
// Items whose behavior the spec never observed stay visible and disabled (plan Q19): Customize
// Page…, Share Folder…, Share Split View…, Live Folders ▸ and Share
// Space…. B77 enabled Change Icon…, Edit Pinned Page ▸ Edit…, Show Unread Badge, Turn “<name>”
// into Space, Export “<name>” into Folder ▸, Move to ▸ Profile ▸ / New Space…, and the split
// row's Change Icon… / Rename….

/// Which tab menu a row shows.
enum SidebarTabMenuKind {
    case favorite
    case pinned
    case today
}

/// Share ▸ with the system share services for a link. [06 §21.5] observed ("系统分享服务").
struct SidebarShareMenu: View {
    let url: URL?

    var body: some View {
        if let url {
            // A text label: the default label's icon would indent every item of the menu.
            ShareLink(item: url) { Text("Share") }
        } else {
            Menu("Share") {}.disabled(true)
        }
    }
}

/// Favorite, pinned and Today tab menus.
struct SidebarTabMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode
    let kind: SidebarTabMenuKind

    /// The disabled "Customize Page…" is in the favorite and Today menus ([06 §21.5] observed),
    /// not in the pinned one ([05 §右键菜单] observed; B122).
    static func showsCustomizePage(_ kind: SidebarTabMenuKind) -> Bool { kind != .pinned }

    var body: some View {
        let id = tab.id
        let link = viewModel.linkURL(for: id)

        // Copy Link (⌘C on a Today tab) · Share ▸ · —
        Button("Copy Link") { if let link { SidebarPasteboard.copy(link) } }
            .disabled(link == nil)
            .modifier(SidebarMenuShortcut(isShown: kind == .today, key: "c"))
        SidebarShareMenu(url: link)
        Divider()

        // Show Unread Badge (favorites only; [05 §context menus] observed, listed before Change
        // Icon…) · Change Icon… · Rename… · Mute (disabled without sound) · Customize Page… (not on
        // pinned tabs: [05 §右键菜单] observed list has none; favorites and Today [06 §21.5])
        if kind == .favorite {
            Toggle("Show Unread Badge", isOn: Binding(
                get: { viewModel.showsUnreadBadge(id) },
                set: { _ in viewModel.toggleUnreadBadge(id) }
            ))
        }
        Button("Change Icon…") { viewModel.beginChangeIcon(id) }
        Button("Rename…") { viewModel.beginRename(id) }
        Button(viewModel.liveState(for: id)?.isMuted == true ? "Unmute" : "Mute") { viewModel.toggleMute(id) }
            .disabled(viewModel.liveState(for: id)?.isAudible != true)
        if Self.showsCustomizePage(kind) {
            Button("Customize Page…") {}.disabled(true)
        }

        switch kind {
        case .favorite, .pinned:
            // Edit Pinned Page ▸ (Replace Pinned URL with Current, disabled until navigated / Edit…)
            Menu("Edit Pinned Page") {
                Button("Replace Pinned URL with Current") { viewModel.replacePinnedURLWithCurrent(id) }
                    .disabled(!viewModel.canReplacePinnedURL(id))
                Button("Edit…") { viewModel.beginEditPinnedPage(id) }
            }
            Divider()
            Button("Open in Split View") { viewModel.openInSplitView(id) }
            Button("Duplicate") { viewModel.duplicateTab(id) }
            if kind == .favorite {
                Menu("Move to") { SidebarProfileMoveMenu(viewModel: viewModel, tab: tab) }
            } else {
                SidebarMoveToSpaceMenu(viewModel: viewModel, itemID: id, currentSpaceID: tab.location.spaceID, profileTabID: id) { space in
                    viewModel.moveTab(id, toSpace: space)
                }
            }
            Divider()
            if kind == .favorite {
                Button("Remove Favorite") { viewModel.removeFavorite(id) }
            } else {
                Button("Remove Pin") { viewModel.unpinTab(id) }
            }

        case .today:
            Divider()
            Button("Add Split View") { viewModel.openInSplitView(id) }
            Button("Duplicate") { viewModel.duplicateTab(id) }
            SidebarMoveToSpaceMenu(viewModel: viewModel, itemID: id, currentSpaceID: tab.location.spaceID) { space in
                viewModel.moveTab(id, toSpace: space)
            }
            Divider()
            let around = viewModel.todayTabs(around: id)
            SidebarArchiveItems(viewModel: viewModel, archiveTitle: "Archive Tab", above: around.above, below: around.below) {
                viewModel.closeTab(id)
            }
        }
    }
}

/// Shows a menu item's shortcut where the capture lists one (Copy Link ⌘C on a Today tab).
private struct SidebarMenuShortcut: ViewModifier {
    let isShown: Bool
    let key: KeyEquivalent

    func body(content: Content) -> some View {
        if isShown { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}

/// Archive Tab / Item · Archive Other Tabs · Archive Tabs Below · Archive Tabs Above, each disabled
/// when it has nothing to act on. [06 §21.5] observed.
struct SidebarArchiveItems: View {
    @ObservedObject var viewModel: SidebarViewModel
    let archiveTitle: String
    let above: [UUID]
    let below: [UUID]
    let archive: () -> Void

    var body: some View {
        Button(archiveTitle, action: archive)
        Button("Archive Other Tabs") { viewModel.archiveTabs(above + below) }
            .disabled(above.isEmpty && below.isEmpty)
        Button("Archive Tabs Below") { viewModel.archiveTabs(below) }
            .disabled(below.isEmpty)
        Button("Archive Tabs Above") { viewModel.archiveTabs(above) }
            .disabled(above.isEmpty)
    }
}

/// Move to ▸ for Today tabs, pinned tabs, folders and split rows: each Space (the current one
/// checked) · — · New Space…, which moves the item into the Space once it is created (B77).
/// [06 §21.5] observed. Pinned tabs also list Profile ▸ first ([05 §context menus] observed).
struct SidebarMoveToSpaceMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    /// The tab, folder or split layout the menu moves.
    let itemID: UUID
    let currentSpaceID: UUID?
    /// Set for a pinned tab: shows Profile ▸ (local profiles, B73) for it.
    var profileTabID: UUID?
    let move: (UUID) -> Void

    var body: some View {
        Menu("Move to") {
            if let profileTabID {
                Menu("Profile") { SidebarProfileItems(viewModel: viewModel, tabID: profileTabID) }
                Divider()
            }
            ForEach(viewModel.menuSpaces, id: \.id) { space in
                Toggle(space.name, isOn: Binding(
                    get: { space.id == currentSpaceID },
                    set: { if $0, space.id != currentSpaceID { move(space.id) } }
                ))
            }
            Divider()
            Button("New Space…") { viewModel.requestNewSpace(moving: itemID) }.disabled(!viewModel.canRequest)
        }
    }
}

/// Favorite ▸ Move to ▸ Profile ▸ <each Profile> (the favorite's profile checked). [06 §21.5]
/// observed: favorites move between profiles, not Spaces.
struct SidebarProfileMoveMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode

    var body: some View {
        Menu("Profile") { SidebarProfileItems(viewModel: viewModel, tabID: tab.id) }
    }
}

/// Each local profile (B73), the tab's own checked; picking another moves the tab there
/// (`TreeOps.moveTabToProfile`). A profile without a Space cannot take a pinned tab: disabled.
struct SidebarProfileItems: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tabID: UUID

    var body: some View {
        let current = viewModel.profileID(ofTab: tabID)
        ForEach(viewModel.menuProfiles, id: \.id) { profile in
            Toggle(profile.name, isOn: Binding(
                get: { profile.id == current },
                set: { if $0, profile.id != current { viewModel.moveTabToProfile(tabID, profileID: profile.id) } }
            ))
            .disabled(profile.id != current && !viewModel.canMoveTab(tabID, toProfile: profile.id))
        }
    }
}

/// Space background menu (the empty sidebar, including the 8 pt gaps between favorite tiles), also
/// behind the Space name row's "More" button (inferred). [06 §21.5] observed:
/// Change Space Icon… · Rename Space… · Edit Theme Color… · Set Profile ▸ · — · New Folder ·
/// Live Folders ▸ · — · Share Space… · Export “<name>” into Folder ▸ · — · Manage Spaces… · — ·
/// Delete Space.
struct SidebarSpaceMenu: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        if let space = viewModel.selectedSpace {
            let canRequest = viewModel.canRequest
            Button("Change Space Icon…") { viewModel.requestFromMenu(.changeSpaceIcon(spaceID: space.id)) }.disabled(!canRequest)
            Button("Rename Space…") { viewModel.requestFromMenu(.renameSpace(spaceID: space.id)) }.disabled(!canRequest)
            Button("Edit Theme Color…") { viewModel.requestFromMenu(.editSpaceTheme(spaceID: space.id)) }.disabled(!canRequest)
            Menu("Set Profile") {
                ForEach(viewModel.menuProfiles, id: \.id) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { profile.id == viewModel.currentProfileID },
                        set: { if $0 { viewModel.setSpaceProfile(space.id, profileID: profile.id) } }
                    ))
                }
                Divider()
                // The New Profile sheet with this Space preselected (B72).
                Button("New Profile…") { viewModel.requestFromMenu(.newProfile(spaceID: space.id)) }.disabled(!canRequest)
            }
            Divider()
            Button("New Folder") { viewModel.requestNewFolder() }
            Menu("Live Folders") {
                Button("GitHub") {}.disabled(true)
            }
            .disabled(true)
            Divider()
            Button("Share Space…") {}.disabled(true)
            let others = viewModel.menuSpaces.filter { $0.id != space.id }
            Menu("Export “\(space.name)” into Folder") {
                ForEach(others, id: \.id) { other in
                    Button(other.name) { viewModel.exportSpace(space.id, intoSpace: other.id) }
                }
            }
            .disabled(others.isEmpty)
            Divider()
            Button("Manage Spaces…") { viewModel.requestFromMenu(.manageSpaces) }.disabled(!canRequest)
            Divider()
            Button("Delete Space", role: .destructive) { viewModel.requestDeleteSpace(space.id) }
                .disabled(!viewModel.canDeleteSpace)
        }
    }
}

/// Folder menu. [06 §21.5] observed: Share Folder… · — · New Nested Folder… ·
/// Turn “<name>” into Space · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ (each Space
/// · — · New Space…) · — · Delete.
struct SidebarFolderMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let folder: Folder

    var body: some View {
        Button("Share Folder…") {}.disabled(true)
        Divider()
        Button("New Nested Folder…") { viewModel.requestNewFolder(parent: folder.id) }
        Button("Turn “\(folder.title)” into Space") { viewModel.turnFolderIntoSpace(folder.id) }
        Divider()
        Button("Change Icon…") { viewModel.beginChangeIcon(folder.id) }
        Button("Rename…") { viewModel.beginRename(folder.id) }
        Divider()
        Button("Duplicate") { viewModel.duplicateFolder(folder.id) }
        SidebarMoveToSpaceMenu(viewModel: viewModel, itemID: folder.id, currentSpaceID: folder.spaceID) { space in
            viewModel.moveFolder(folder.id, toSpace: space)
        }
        Divider()
        Button("Delete") { viewModel.deleteFolder(folder.id) }
    }
}

/// Split row menu (the combined row of a split view). [06 §21.5] observed:
/// Share Split View… · — · Separate All Tabs · Add Tab… · Convert to Vertical Split View · — ·
/// Tab Options (disabled heading) · one submenu per tab · — · Change Icon… · Rename… · — ·
/// Duplicate · Move to ▸ · — · Archive Item · Archive Other Tabs · Archive Tabs Below ·
/// Archive Tabs Above.
struct SidebarSplitGroupMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let group: SidebarSplitGroup

    var body: some View {
        let layoutID = group.layoutID
        Button("Share Split View…") {}.disabled(true)
        Divider()
        Button("Separate All Tabs") { viewModel.separateAllTabs(layoutID) }
        Button("Add Tab…") { viewModel.addTabToSplit(layoutID) }
        // The title flips once the split is vertical (inferred).
        Button(viewModel.isHorizontalSplit(layoutID) ? "Convert to Vertical Split View" : "Convert to Horizontal Split View") {
            viewModel.toggleSplitAxis(layoutID)
        }
        Divider()
        Button("Tab Options") {}.disabled(true)
        ForEach(group.members, id: \.id) { member in
            SidebarSplitMemberMenu(viewModel: viewModel, tab: member)
        }
        Divider()
        Button("Change Icon…") { viewModel.beginChangeIcon(layoutID) }
        Button("Rename…") { viewModel.beginRename(layoutID) }
        Divider()
        Button("Duplicate") { viewModel.duplicateSplitGroup(layoutID) }
        SidebarMoveToSpaceMenu(viewModel: viewModel, itemID: layoutID, currentSpaceID: viewModel.splitLayout(layoutID)?.spaceID) { space in
            viewModel.moveSplitGroup(layoutID, toSpace: space)
        }
        Divider()
        let around = viewModel.todayTabs(aroundGroup: group)
        SidebarArchiveItems(viewModel: viewModel, archiveTitle: "Archive Item", above: around.above, below: around.below) {
            viewModel.closeSplitGroup(layoutID)
        }
    }
}

/// <tab title> ▸ inside the split row menu. [06 §21.5] observed: Separate from Split View · — ·
/// Share ▸ · Mute · Copy Link · Copy link as Markdown · — · Archive Item.
struct SidebarSplitMemberMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode

    var body: some View {
        let id = tab.id
        let link = viewModel.linkURL(for: id)
        Menu(tab.displayTitle.isEmpty ? "New Tab" : tab.displayTitle) {
            Button("Separate from Split View") { viewModel.separateFromSplit(id) }
            Divider()
            SidebarShareMenu(url: link)
            Button(viewModel.liveState(for: id)?.isMuted == true ? "Unmute" : "Mute") { viewModel.toggleMute(id) }
                .disabled(viewModel.liveState(for: id)?.isAudible != true)
            Button("Copy Link") { if let link { SidebarPasteboard.copy(link) } }
                .disabled(link == nil)
            Button("Copy link as Markdown") {
                if let text = viewModel.markdownLink(for: id) { SidebarPasteboard.copyText(text) }
            }
            .disabled(link == nil)
            Divider()
            Button("Archive Item") { viewModel.closeTab(id) }
        }
    }
}

extension SidebarPasteboard {
    /// Plain text on the general pasteboard ("Copy link as Markdown").
    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
