import Foundation

// Titles and structure of the menu bar (plan B62). Acceptance: [01] all sections; groups and
// icons from [01 §菜单项图标与缩进] (E20 capture, observed). Each `[String]` below is one group,
// in order; separators fall between groups. Only items we build are listed (see the report of
// B62 for the [01] items that are not built yet); a group that would be empty is left out.

enum MenuBarCatalog {
    /// Title of the hidden menu that carries [02] shortcuts no [01] menu lists (Archive Tab ⌘W,
    /// Go to Sidebar Item ⌘1…⌘9, Open Extensions ⌘E). `MenuBarAdjuster` hides it; its keys still work.
    static let keyOnlyMenuTitle = "OpenArcShortcuts"

    /// Our Edit ▸ Find ▸ submenu; any other "Find" submenu is a system duplicate.
    static let findMenuTitle = "Find"

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
    /// observed: magnifier +/− on Zoom In / Zoom Out, the download tray on Save Page As).
    static let standardIconActions: [String: [String: String]] = [
        "View": ["Zoom In": "zoomIn:", "Zoom Out": "zoomOut:"],
        "File": ["Save Page As": "saveDocument:"],
    ]

    /// Edit items that follow Copy directly, in this order ([01 §Edit] observed: Copy · Copy URL ·
    /// Copy URL as Markdown · Copy URL as Quote · Paste). SwiftUI can only place them after the
    /// pasteboard group (after Select All); `MenuBarAdjuster` moves them.
    static let afterCopyItems = ["Copy URL", "Copy URL as Markdown"]

    // MARK: Groups we build, per menu ([01] order; [01 §菜单项图标与缩进] groups)

    /// Arc menu, between About and Services. [01 §菜单项图标与缩进] observed: Settings… · Share Arc ·
    /// Set as Default Browser ‖ Import from Another Browser… · Check for Updates…. Share Arc is not
    /// built.
    static let appGroups: [[String]] = [
        ["Settings…", "Set as Default Browser"],
        ["Import from Another Browser…", "Check for Updates…"],
    ]

    /// File. [01 §菜单项图标与缩进] observed groups. New Profile and Share… are not built.
    static let fileGroups: [[String]] = [
        ["New Tab…", "New Window", "Blank Window", "New Incognito Window", "New Little Arc Window", "Restore Last Closed Tab"],
        ["Open Command Bar"],
        ["New Easel"],
        ["Close Window"],
        ["Capture…", "Capture Full Page", "Capture in Portrait Mode", "Save Page As", "Print"],
    ]

    /// View. [01 §菜单项图标与缩进] observed (view-crop.png): Appearance ‖ Hide Sidebar · Show Toolbar ·
    /// Collapse Pinned Tabs ‖ Stop Loading · Refresh the Page · Force Refresh the Page ‖ split items ‖
    /// zoom items ‖ Cast ‖ Developer ‖ Enter Full Screen (system). Only the zoom group and Enter Full
    /// Screen carry icons, so only they are indented. Collapse Pinned Tabs and Cast are not built.
    static let viewGroups: [[String]] = [
        ["Appearance"],
        ["Hide Sidebar", "Show Toolbar"],
        ["Stop Loading", "Refresh the Page", "Force Refresh the Page"],
        ["Add Split View", "Close this Split Pane", "Separate Page from Split View", "Expand Current Split"],
        ["Zoom to Actual Size", "Zoom In", "Zoom Out"],
        ["Developer"],
    ]

    /// Spaces. [01 §Spaces] observed order, [01 §菜单项图标与缩进] groups. Change Profile and
    /// Manage Spaces… are listed in [01]; Manage Spaces… is built (the Library's Spaces board).
    /// The Space list sits between Previous Space and Manage Spaces….
    static let spacesGroups: [[String]] = [
        ["New Space…", "Edit Theme…", "Rename Space"],
        ["Next Space", "Previous Space"],
        // One item per Space, then:
        ["Manage Spaces…"],
    ]

    /// Tabs. [01 §Tabs] observed, groups from the E20 capture (tabs-crop.png): New Tab… · Pin Tab ·
    /// New Folder… ‖ Next Tab · Previous Tab · Reveal Tab in Sidebar ‖ Clear Today · Reset all tabs
    /// in this Space. Reveal Tab in Sidebar and Reset all tabs in this Space are not built.
    static let tabsGroups: [[String]] = [
        ["New Tab…", "Pin/Unpin Tab", "New Folder…"],
        ["Next Tab", "Previous Tab"],
        ["Clear Today"],
    ]

    /// Archive. [01 §Archive] observed; E20 (archive-crop.png): Go Back · Go Forward ‖ View History ·
    /// View Archive… · Clear Archive. View History and Clear Archive are not built.
    static let archiveGroups: [[String]] = [
        ["Go Back", "Go Forward"],
        ["View Archive…"],
    ]

    /// Extensions. [01 §Extensions] observed: one group, no icons.
    static let extensionsGroups: [[String]] = [
        ["Add Extension…", "Manage Extensions…"],
    ]

    /// Window, our group between the system window groups and Bring All to Front. [01 §Window],
    /// [01 §菜单项图标与缩进] observed: no icons, no indent.
    static let windowGroups: [[String]] = [
        ["Open Library…", "View Downloads…", "View Easels…", "View Media…", "View Boosts…"],
    ]

    /// Key-only commands ([02] observed keys, in no [01] menu).
    static let keyOnlyItems: [String] = ["Archive Tab", "Open Extensions"]
        + (1...8).map { "Go to Sidebar Item \($0)" } + ["Go to Last Sidebar Item"]
}
