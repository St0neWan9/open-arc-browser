import Foundation
import os

// The web page's right-click menu (plan B124; bridge: chromium-bridge/include/OpenArcCore/
// OACContextMenu.h).
//
// Spec: docs/arc-spec/05-surfaces.md §右键菜单, "网页内容右键菜单 (E29)" (observed): Arc's page, link,
// image, selection and editable-field menus, item by item, as a native menu.
//
// The engine builds its own items for the click (Back, Copy Image, extension items…) and reports
// them with what was clicked as `TabEvent.contextMenuRequested`. The shell orders them with its own
// items (Open Link in Split View, Open Link in Little Arc, Capture Image…) the way Arc does, shows a
// native menu with `PageContextMenuSession.present`, and runs an engine item with `perform`.

/// What a right-click hit.
public struct PageContextMenuTarget: Hashable, Sendable {
    public enum Media: String, Hashable, Sendable {
        case none, image, video, audio, canvas, plugin, file
    }

    /// The edit commands an editable field allows.
    public struct EditFlags: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let canUndo = EditFlags(rawValue: 1 << 0)
        public static let canRedo = EditFlags(rawValue: 1 << 1)
        public static let canCut = EditFlags(rawValue: 1 << 2)
        public static let canCopy = EditFlags(rawValue: 1 << 3)
        public static let canPaste = EditFlags(rawValue: 1 << 4)
        public static let canSelectAll = EditFlags(rawValue: 1 << 5)
    }

    public var linkURL: URL?
    public var linkText: String
    /// The image, video or audio source.
    public var sourceURL: URL?
    public var media: Media
    /// The image has loaded (Copy Image works).
    public var hasImageContents: Bool
    /// The selected text (in a field, the word macOS selected under the pointer).
    public var selectionText: String
    public var isEditable: Bool
    public var isPasswordField: Bool
    public var editFlags: EditFlags
    public var pageURL: URL?
    /// The click, in points, in the page's view (origin top left, y down).
    public var x: Double
    public var y: Double

    public init(
        linkURL: URL? = nil, linkText: String = "", sourceURL: URL? = nil, media: Media = .none,
        hasImageContents: Bool = false, selectionText: String = "", isEditable: Bool = false,
        isPasswordField: Bool = false, editFlags: EditFlags = [], pageURL: URL? = nil,
        x: Double = 0, y: Double = 0
    ) {
        self.linkURL = linkURL
        self.linkText = linkText
        self.sourceURL = sourceURL
        self.media = media
        self.hasImageContents = hasImageContents
        self.selectionText = selectionText
        self.isEditable = isEditable
        self.isPasswordField = isPasswordField
        self.editFlags = editFlags
        self.pageURL = pageURL
        self.x = x
        self.y = y
    }

    /// A link was right-clicked.
    public var isLink: Bool { linkURL != nil }
    /// An image was right-clicked.
    public var isImage: Bool { media == .image }
    /// Text is selected (trimmed text is not empty).
    public var hasSelection: Bool { !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// What an engine item does, so the shell can place it without knowing the engine's command
/// numbers. Raw values match the bridge's `OACContextMenuItemRole`.
public enum PageContextMenuRole: Int, Hashable, Sendable, CaseIterable {
    case other = 0
    case back, forward, reload, savePage, print, cast, translate, viewSource, inspect
    case openLinkInNewTab, openLinkInNewWindow, openLinkInIncognito, saveLinkAs, copyLinkAddress
    case copy, copyLinkToHighlight, searchWeb, lookUp
    case openImageInNewTab, saveImageAs, copyImage, copyImageAddress
    case emoji, undo, redo, cut, paste, pasteAndMatchStyle, selectAll, languageSettings, writingDirection
    case spelling, importPasswords
    case speech, `extension`
}

/// One engine item of a menu.
public struct PageContextMenuItem: Hashable, Sendable, Identifiable {
    public enum Kind: Int, Hashable, Sendable {
        case command = 0, checkbox = 1, separator = 2, submenu = 3
    }

    /// Pass to `PageContextMenuSession.perform`. 0 for separators.
    public var id: Int
    public var kind: Kind
    public var role: PageContextMenuRole
    /// The engine's title.
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool
    public var isVisible: Bool
    /// For extension items: the extension's id.
    public var extensionID: String?
    public var children: [PageContextMenuItem]

    public init(
        id: Int, kind: Kind = .command, role: PageContextMenuRole, title: String, isEnabled: Bool = true,
        isChecked: Bool = false, isVisible: Bool = true, extensionID: String? = nil,
        children: [PageContextMenuItem] = []
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isVisible = isVisible
        self.extensionID = extensionID
        self.children = children
    }

    public static func separator() -> PageContextMenuItem {
        PageContextMenuItem(id: 0, kind: .separator, role: .other, title: "", isEnabled: false)
    }
}

/// The live side of one menu: shows it, runs engine items, reports items the engine changed while
/// it is open. Thread-safe; equal by identity. The menu ends with `close()`, after `present`
/// returned, or when the last reference goes away.
public final class PageContextMenuSession: Sendable, Hashable {
    public typealias Present = @MainActor @Sendable (AnyObject) -> Bool
    public typealias Perform = @MainActor @Sendable (Int) -> Void
    public typealias Close = @Sendable () -> Void
    public typealias ItemUpdate = @MainActor @Sendable (PageContextMenuItem) -> Void

    private let presentHandler: Present
    private let performHandler: Perform
    private let closeHandler: OSAllocatedUnfairLock<Close?>
    private let updateHandler = OSAllocatedUnfairLock<ItemUpdate?>(initialState: nil)

    public init(present: @escaping Present, perform: @escaping Perform, close: @escaping Close) {
        presentHandler = present
        performHandler = perform
        closeHandler = OSAllocatedUnfairLock(initialState: close)
    }

    deinit {
        take()?()
    }

    /// Shows `menu` (an `NSMenu`; `AnyObject` keeps this module free of AppKit) at the click over
    /// the page and returns once it closed; the session then ends. False when the session already
    /// ended or the page cannot show it.
    @MainActor
    public func present(_ menu: AnyObject) -> Bool {
        guard !isClosed else { return false }
        return presentHandler(menu)
    }

    /// Runs an engine item (its `id`). Ignored after `close()`.
    @MainActor
    public func perform(_ itemID: Int) {
        guard !isClosed else { return }
        performHandler(itemID)
    }

    /// Ends the menu without a choice. Idempotent.
    public func close() {
        take()?()
    }

    public var isClosed: Bool { closeHandler.withLock { $0 == nil } }

    /// Called with an item the engine changed while the menu is open (Copy Link to Highlight turns
    /// enabled once its link is ready).
    public func onItemUpdate(_ handler: ItemUpdate?) {
        updateHandler.withLock { $0 = handler }
    }

    /// Engine side: an item changed.
    @MainActor
    public func itemDidUpdate(_ item: PageContextMenuItem) {
        guard !isClosed, let handler = updateHandler.withLock({ $0 }) else { return }
        handler(item)
    }

    private func take() -> Close? {
        closeHandler.withLock { state in
            defer { state = nil }
            return state
        }
    }

    public static func == (lhs: PageContextMenuSession, rhs: PageContextMenuSession) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A right-click menu the page asked for (`TabEvent.contextMenuRequested`).
public struct PageContextMenu: Hashable, Sendable {
    public var target: PageContextMenuTarget
    /// The engine's items, in the engine's order.
    public var items: [PageContextMenuItem]
    public let session: PageContextMenuSession

    public init(target: PageContextMenuTarget, items: [PageContextMenuItem], session: PageContextMenuSession) {
        self.target = target
        self.items = items
        self.session = session
    }

    /// The first visible top-level item with `role`.
    public func item(_ role: PageContextMenuRole) -> PageContextMenuItem? {
        items.first { $0.role == role && $0.isVisible && $0.kind != .separator }
    }

    /// Every visible top-level item with `role`, in order.
    public func items(_ role: PageContextMenuRole) -> [PageContextMenuItem] {
        items.filter { $0.role == role && $0.isVisible && $0.kind != .separator }
    }
}

// MARK: - Extension action menu (plan B116 / B124)

extension EngineExtensions {
    /// Engines without extension menus: no items.
    public func actionMenuItems(extensionID: String, tabID: EngineTabID) async -> [PageContextMenuItem] { [] }
    public func performActionMenuItem(_ itemID: Int, extensionID: String, tabID: EngineTabID) async {}
}

// MARK: - Fake engine

/// What a fake menu's session saw (tests).
// @unchecked: every mutable stored property is read and written only under `lock`.
public final class FakePageContextMenuRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var presentedMenus: [AnyObject] = []
    private var performedIDs: [Int] = []
    private var closeCount = 0

    public init() {}

    public var presented: [AnyObject] { lock.withLock { presentedMenus } }
    public var performed: [Int] { lock.withLock { performedIDs } }
    public var isClosed: Bool { lock.withLock { closeCount > 0 } }

    public func notePresented(_ menu: AnyObject) { lock.withLock { presentedMenus.append(menu) } }
    public func notePerformed(_ id: Int) { lock.withLock { performedIDs.append(id) } }
    public func noteClosed() { lock.withLock { closeCount += 1 } }
}

/// The engine items a Chromium-like engine offers for a click, for FakeEngine. Ids are the roles'
/// raw values plus 1000 (extension items keep the ids they are given).
public enum FakePageContextMenu {
    public static func id(_ role: PageContextMenuRole) -> Int { 1000 + role.rawValue }

    public static func items(for target: PageContextMenuTarget) -> [PageContextMenuItem] {
        func item(_ role: PageContextMenuRole, _ title: String, enabled: Bool = true) -> PageContextMenuItem {
            PageContextMenuItem(id: id(role), role: role, title: title, isEnabled: enabled)
        }
        var items: [PageContextMenuItem] = []
        if target.isLink {
            items += [item(.openLinkInNewTab, "Open Link in New Tab"), item(.openLinkInNewWindow, "Open Link in New Window"),
                      item(.openLinkInIncognito, "Open Link in Incognito Window"), .separator(),
                      item(.saveLinkAs, "Save Link As…"), item(.copyLinkAddress, "Copy Link Address")]
        }
        if target.isImage {
            items += [item(.openImageInNewTab, "Open Image in New Tab"), item(.saveImageAs, "Save Image As…"),
                      item(.copyImage, "Copy Image", enabled: target.hasImageContents),
                      item(.copyImageAddress, "Copy Image Address")]
        }
        if target.isEditable {
            items += [item(.emoji, "Emoji & Symbols"), item(.undo, "Undo"), item(.redo, "Redo"), .separator(),
                      item(.cut, "Cut"), item(.copy, "Copy"), item(.paste, "Paste"),
                      item(.pasteAndMatchStyle, "Paste and Match Style"), item(.selectAll, "Select All")]
        } else if !target.isLink && !target.isImage && !target.hasSelection {
            items += [item(.back, "Back", enabled: false), item(.forward, "Forward", enabled: false), item(.reload, "Reload"),
                      .separator(), item(.savePage, "Save As…"), item(.print, "Print…")]
        } else if target.hasSelection {
            items += [item(.copy, "Copy"), item(.copyLinkToHighlight, "Copy Link to Highlight", enabled: false),
                      item(.searchWeb, "Search Google for “\(target.selectionText)”"), item(.print, "Print…")]
        }
        if target.hasSelection && !target.isLink { items.insert(item(.lookUp, "Look Up “\(target.selectionText)”"), at: 0) }
        if target.isEditable {
            items += [.separator(), item(.languageSettings, "Language Settings"),
                      PageContextMenuItem(id: id(.writingDirection), kind: .submenu, role: .writingDirection, title: "Writing Direction")]
        }
        items += [.separator(), item(.viewSource, "View Page Source"), item(.inspect, "Inspect")]
        if target.hasSelection {
            items.append(PageContextMenuItem(id: id(.speech), kind: .submenu, role: .speech, title: "Speech"))
        }
        return items
    }
}
