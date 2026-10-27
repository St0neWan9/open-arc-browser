import SwiftUI
import OpenArcModel
import OpenArcDesign

// The incognito window's sidebar and menus (plan B48), docs/arc-spec/06-flows.md §20:
// - fixed near-black neutral colors, no Space theme (`ThemeDerivation.incognitoPalette`);
// - no badge: the only mark is the Space-name row "Incognito Tabs" (x 13, no icon);
// - no favorites block (the rows below move up), no pinned area and no divider; "Clear" at the
//   right of the name row once there are tabs;
// - a dock with Home and "+" only ("+" opens the command bar for a new tab, not New Space);
// - a tab menu without Pin, Move to Space or Add to Favorites;
// - the Spaces menu disabled.

extension SidebarViewModel {
    /// The incognito window's palette: the fixed colors of [06 §20.1] (observed, dark), in the
    /// appearance its pages use (View ▸ Appearance; Automatic follows the system). Which setting
    /// drives Arc's incognito chrome is inferred: the E19 capture set View ▸ Appearance to Dark.
    /// The light colors are unknown ([06 §20.5]); `incognitoPalette` keeps a neutral fallback.
    var incognitoPalette: ThemePalette {
        let scheme = controller.webAppearance.colorScheme(spaceAppearance: controller.systemAppearance)
        return ThemeDerivation.incognitoPalette(appearance: scheme == .dark ? .dark : .light)
    }

    /// Drop targets an incognito window refuses: anything that pins, makes a favorite, enters a
    /// folder or moves to another Space. [06 §20.2] observed: no favorites, no pinned area, no
    /// Space icons in the dock.
    func incognitoAllowsDrop(on target: SidebarDropTarget) -> Bool {
        guard isIncognito else { return true }
        switch target {
        case .pinnedAreaTop, .pinnedAreaEnd, .favoriteGap, .dockSpace, .row(_, .into): return false
        case .row, .todayAreaEnd: return true
        }
    }

    /// The dock's "+": New Space in a normal window; the command bar for a new tab in an incognito
    /// window. [06 §20.2] observed ("点「+」打开命令栏(新标签),不是新建 Space").
    func dockPlusClicked() {
        requestFromMenu(isIncognito ? .openCommandBar(.newTab) : .newSpace)
    }

    /// Today tabs before / after `id`, in list order. For the incognito tab menu.
    func todayTabs(around id: UUID) -> (above: [UUID], below: [UUID]) {
        guard let spaceID = selectedSpaceID else { return ([], []) }
        let order = workspace.today(spaceID: spaceID).map(\.id)
        guard let index = order.firstIndex(of: id) else { return ([], []) }
        return (Array(order[..<index]), Array(order[(index + 1)...]))
    }

    /// Archive Other Tabs / Archive Tabs Below / Archive Tabs Above. [06 §20.2] observed items;
    /// what each archives follows the names (inferred).
    func archiveTabs(_ ids: [UUID]) {
        for id in ids { closeTab(id) }
    }
}

/// The incognito tab row menu, in the observed order. [06 §20.2] observed:
/// Copy Link · Share · — · Change Icon… · Rename… · Mute · — · Add Split View · Duplicate · — ·
/// Archive Tab · Archive Other Tabs / Archive Tabs Below / Archive Tabs Above (disabled with a
/// single tab). No Pin, no Move to Space, no Add to Favorites.
struct IncognitoTabMenu: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode

    var body: some View {
        let id = tab.id
        let canRequest = viewModel.canRequest
        let around = viewModel.todayTabs(around: id)

        Button("Copy Link") {
            if let url = viewModel.linkURL(for: id) { SidebarPasteboard.copy(url) }
        }
        .disabled(viewModel.linkURL(for: id) == nil)
        Button("Share") { viewModel.requestFromMenu(.share(tabID: id)) }.disabled(!canRequest)
        Divider()
        Button("Change Icon…") { viewModel.requestFromMenu(.changeIcon(tabID: id)) }.disabled(!canRequest)
        Button("Rename…") { viewModel.beginRename(id) }
        Button(viewModel.liveState(for: id)?.isMuted == true ? "Unmute" : "Mute") { viewModel.toggleMute(id) }
            .disabled(viewModel.liveState(for: id)?.isAudible != true)
        Divider()
        Button("Add Split View") { viewModel.openInSplitView(id) }
        Button("Duplicate") { viewModel.duplicateTab(id) }
        Divider()
        Button("Archive Tab") { viewModel.closeTab(id) }
        Button("Archive Other Tabs") { viewModel.archiveTabs(around.above + around.below) }
            .disabled(around.above.isEmpty && around.below.isEmpty)
        Button("Archive Tabs Below") { viewModel.archiveTabs(around.below) }
            .disabled(around.below.isEmpty)
        Button("Archive Tabs Above") { viewModel.archiveTabs(around.above) }
            .disabled(around.above.isEmpty)
    }
}

/// "Clear" at the right of the "Incognito Tabs" row while the window has tabs: archives them.
/// [06 §20.2] observed (shown once there are tabs); its effect is inferred ([06 §20.5]: closes
/// every incognito tab). Placement inferred: right-aligned just left of the hovered "More" button.
struct IncognitoClearButton: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout

    var body: some View {
        if !viewModel.snapshot.today.isEmpty {
            let s = Metrics.Sidebar.self
            let style = Typography.spaceName
            let width = SidebarLocalTokens.clearButtonWidth
            Button {
                viewModel.clearToday()
            } label: {
                Text("Clear")
                    .font(Typography.dividerClear.font)
                    .foregroundStyle(viewModel.palette.ink(\.spaceName).swiftUI)
                    .frame(width: width, height: CGFloat(style.lineHeight), alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openarc.sidebar.incognitoClearButton")
            .offset(x: CGFloat(s.spaceMoreButtonFrame.x) - SidebarLocalTokens.spaceMoreHoverWidth - width,
                        y: CGFloat(s.spaceNameTop) - layout.contentShift)
        }
    }
}
