import Foundation

// Titles and structure of the menu bar (plans B62, B72). Acceptance: [01] all sections; groups and
// icons from [01 §菜单项图标与缩进] (E20 capture, observed). Each `[String]` below is one group,
// in order; separators fall between groups. A group that would be empty is left out.
//
// Every [01] item is built except the ones in `omittedItems`, each with its reason. The Archive
// menu's View History and Clear Archive are plan B69's.

enum MenuBarCatalog {
    /// Title of the hidden menu that carries [02] shortcuts no [01] menu lists (Archive Tab ⌘W,
    /// Go to Sidebar Item ⌘1…⌘9, Open Extensions ⌘E) and the [02] aliases of visible items
    /// (`keyOnlyAliases`, B85). `MenuBarAdjuster` hides it; its keys still work.
    static let keyOnlyMenuTitle = "OpenArcShortcuts"

    /// Our Edit ▸ Find ▸ submenu; any other "Find" submenu is a system duplicate.
    static let findMenuTitle = "Find"

    /// [01] items we do not build, with the reason (plan B72).
    static let omittedItems: [String: String] = [
        // Arc ▸ Sign Out: Open Arc has no account; sync uses the iCloud account of the Mac.
        "Sign Out": "no account to sign out of (iCloud sync)",
        // Help ▸ Export Arc Notes: Notes are gone from Arc 1.170 ([06 §23]) and not in Open Arc.
        "Export Arc Notes": "no Notes feature",
        // Help ▸ Troubleshooting ▸ Record Trace / Open Task Manager: need engine tracing and a
        // process list the bridge does not expose.
        "Record Trace": "needs engine tracing support",
        "Open Task Manager": "needs a process list from the engine",
        // Edit ▸ Find ▸ Find and Replace: the find bar has no replace field and the engine offers
        // no replace in page text; [01]/[02] record only the item and ⌥⌘F, not what it does in
        // Arc (B122: hidden, decision pending).
        "Find and Replace": "no replace step in the find bar; Arc's behavior not recorded",
    ]

    /// System items whose titles differ in [01]/[02], by action. Observed: "Hide Other Windows"
    /// ([01 §Arc], [02 §窗口与应用] ⌥⌘H); "Minimize Window" ([01 §Window], [02] ⌘M).
    static let systemTitles: [String: String] = [
        "hideOtherApplications:": "Hide Other Windows",
        "performMiniaturize:": "Minimize Window",
    ]

    /// Our items that stand for a standard AppKit command, by menu and title → that command's
    /// action. macOS picks a menu item's standard icon from its action; SwiftUI buttons have none,
    /// so `MenuBarAdjuster` gives these items the image macOS uses for the action. In Arc these
    /// icons are what indent View's zoom group and File's last group ([01 §菜单项图标与缩进]
    /// observed: magnifier +/− on Zoom In / Zoom Out, the download tray on Save Page As, the
    /// clipboard on Paste and Match Style).
    static let standardIconActions: [String: [String: String]] = [
        "View": ["Zoom In": "zoomIn:", "Zoom Out": "zoomOut:"],
        "File": ["Save Page As": "saveDocument:"],
        "Edit": ["Paste and Match Style": "pasteAndMatchStyle:"],
    ]

    /// Edit items that SwiftUI can only place after the pasteboard group (after Select All), each
    /// list moved right after the system item with that action ([01 §Edit] observed order: Copy ·
    /// Copy URL · Copy URL as Markdown · Copy URL as Quote · Paste · Paste and Match Style).
    static let itemsAfter: [(action: String, titles: [String])] = [
        ("copy:", ["Copy URL", "Copy URL as Markdown", "Copy URL as Quote"]),
        ("paste:", ["Paste and Match Style"]),
    ]

    /// Our Edit ▸ Find ▸ items. [01 §Edit] observed; keys [02 §页面与导航] observed.
    static let findItems = ["Find…", "Find Next", "Find Previous", "Use Selection to Find", "Jump to Selection"]

    /// The system Edit submenus that follow Find ([01 §Edit] observed, plan Q15). SwiftUI's
    /// `TextEditingCommands` adds the first four; Format comes from `TextFormattingCommands` as a
    /// top-level menu, and `MenuBarAdjuster` shows it inside Edit instead.
    static let systemEditSubmenus = ["Spelling and Grammar", "Substitutions", "Transformations", "Speech", "Format"]

    /// Identifier of the Edit ▸ Format item `MenuBarAdjuster` adds.
    static let formatMirrorIdentifier = "org.openarc.menu.format"

    // MARK: Groups we build, per menu ([01] order; [01 §菜单项图标与缩进] groups)

    /// Arc menu, between About and Services. [01 §菜单项图标与缩进] observed: Settings… · Share Arc ·
    /// Set as Default Browser ‖ Import from Another Browser… · Check for Updates…. Share Arc is
    /// ours: Share Open Arc.
    static let appGroups: [[String]] = [
        ["Settings…", "Share Open Arc", "Set as Default Browser"],
        ["Import from Another Browser…", "Check for Updates…"],
    ]

    /// Arc menu, after the system Services item in its group ([01 §菜单项图标与缩进] observed:
    /// Services · Privacy Policy).
    static let appServicesGroupItems = ["Privacy Policy"]

    /// File. [01 §菜单项图标与缩进] observed groups.
    static let fileGroups: [[String]] = [
        ["New Tab…", "New Window", "Blank Window", "New Incognito Window", "New Little Arc Window", "Restore Last Closed Tab"],
        ["Open Command Bar"],
        ["New Profile", "New Easel"],
        ["Close Window"],
        ["Share…", "Capture…", "Capture Full Page", "Capture in Portrait Mode", "Save Page As", "Print"],
    ]

    /// View. [01 §菜单项图标与缩进] observed (view-crop.png): Appearance ‖ Hide Sidebar · Show Toolbar ·
    /// Collapse Pinned Tabs ‖ Stop Loading · Refresh the Page · Force Refresh the Page ‖ split items ‖
    /// zoom items ‖ Cast ‖ Developer ‖ Enter Full Screen (system). Only the zoom group and Enter Full
    /// Screen carry icons, so only they are indented.
    static let viewGroups: [[String]] = [
        ["Appearance"],
        ["Hide Sidebar", "Show Toolbar", "Collapse Pinned Tabs"],
        ["Stop Loading", "Refresh the Page", "Force Refresh the Page"],
        ["Add Split View", "Close this Split Pane", "Separate Page from Split View", "Expand Current Split"],
        ["Zoom to Actual Size", "Zoom In", "Zoom Out"],
        ["Cast"],
        ["Developer"],
    ]

    /// Spaces. [01 §Spaces] observed order, [01 §菜单项图标与缩进] groups. The Space list sits
    /// between Previous Space and Manage Spaces…. An incognito window lists every Space greyed and has no Change Profile
    /// ([06 §20.2] observed).
    static let spacesGroups: [[String]] = [
        ["New Space…", "Edit Theme…", "Rename Space", "Change Profile"],
        ["Next Space", "Previous Space"],
        // One item per Space, then:
        ["Manage Spaces…"],
    ]

    /// Tabs. [01 §Tabs] observed, groups from the E20 capture (tabs-crop.png): New Tab… · Pin Tab ·
    /// New Folder… ‖ Next Tab · Previous Tab · Reveal Tab in Sidebar · (untitled disabled submenu,
    /// E27) ‖ Clear Today · Reset all tabs in this Space.
    static let tabsGroups: [[String]] = [
        ["New Tab…", "Pin/Unpin Tab", "New Folder…"],
        ["Next Tab", "Previous Tab", "Reveal Tab in Sidebar", tabsPlaceholderSubmenuTitle],
        ["Clear Today", "Reset all tabs in this Space"],
    ]

    /// Tabs ▸ the untitled, disabled submenu after Reveal Tab in Sidebar and its three disabled
    /// items, literally "Item 1" … "Item 3". [01 §Tabs] E27 observed; shown disabled (plan Q19).
    static let tabsPlaceholderSubmenuTitle = ""
    static let tabsPlaceholderSubmenuItems = ["Item 1", "Item 2", "Item 3"]

    /// Archive. [01 §Archive] observed; E20 (archive-crop.png): Go Back · Go Forward ‖ View History ·
    /// View Archive… · Clear Archive. All built (B69).
    static let archiveGroups: [[String]] = [
        ["Go Back", "Go Forward"],
        ["View History", "View Archive…", "Clear Archive"],
    ]

    /// Extensions. [01 §Extensions] observed: one group, no icons.
    static let extensionsGroups: [[String]] = [
        ["Add Extension…", "Manage Extensions…"],
    ]

    /// Window: our item at the top of the system window group ([01 §Window] observed: Stay On Top ·
    /// Minimize Window · …).
    static let windowSystemGroupItems = ["Stay On Top"]

    /// Window, our group between the system window groups and Bring All to Front. [01 §Window],
    /// [01 §菜单项图标与缩进] observed: no icons, no indent.
    static let windowGroups: [[String]] = [
        ["Open Library…", "View Downloads…", "View Easels…", "View Media…", "View Boosts…"],
    ]

    /// Help, after the system search field. [01 §Help] observed items; no icons
    /// ([01 §菜单项图标与缩进] observed). The groups are ours (not recorded). No Show Welcome Again:
    /// Arc's Help has none (B122). For development, a launch with an empty `OPENARC_DATA_DIR` is a
    /// first launch and shows onboarding.
    static let helpGroups: [[String]] = [
        // Restore Data: our local meaning (plan Q18, B117): restore the sidebar from a local backup.
        ["Getting Started", "Essential Keyboard Shortcuts", "Contact the Team", "Visit Help Center", "Restore Data"],
        ["Troubleshooting"],
    ]

    /// Help ▸ Troubleshooting ▸ ([01 §Help] observed "Reveal Arc Data", "Copy Arc Info"; our name).
    static let troubleshootingItems = ["Reveal Open Arc Data", "Copy Open Arc Info"]

    /// Key-only commands ([02] observed keys, in no [01] menu; plan Q16), in menu order.
    static let keyOnlyItems: [String] = ["Archive Tab"] + (1...8).map { "Go to Sidebar Item \($0)" }
        + ["Go to Last Sidebar Item", "Open Extensions", "Find and Replace"] + keyOnlyAliases.map(\.title)

    /// The [02] alternative keys of visible items, in the key-only menu (plan B85): each item's
    /// title and the table entry whose second key it binds. ⌘} / ⌘{ [02 §标签与侧边栏], ⌘← / ⌘→
    /// [02 §页面与导航], F12 [02 §开发者], all observed.
    static let keyOnlyAliases: [(title: String, shortcut: AppShortcut)] = [
        ("Next Tab", .nextTab), ("Previous Tab", .previousTab),
        ("Go Back", .goBack), ("Go Forward", .goForward),
        ("Developer Tools", .developerTools),
    ]
}
