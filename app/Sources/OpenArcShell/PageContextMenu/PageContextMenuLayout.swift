import Foundation
import OpenArcEngine

// The web page's right-click menu as Arc orders it (plan B124). Pure: no AppKit, so the order is
// unit-tested; `PageContextMenuPresenter` turns the entries into an NSMenu.
//
// Spec: docs/arc-spec/05-surfaces.md §右键菜单, "网页内容右键菜单 (E29)" (observed items and order;
// "‖" are separators):
// - Page: Back · Forward · Reload ‖ Save As… · Print… · Cast… · Translate to English ‖
//   View Page Source · Inspect.
// - Link: Open Link in New Tab · Open Link in New Window · Open Link in Split View ·
//   Open Link in Little Arc · Open Link in Incognito Window ‖ Save Link As… · Copy Link Address ‖
//   Copy · Copy Link to Highlight · Search Google for "…" · Print… ‖ Inspect ‖ Speech ▸ ‖ Services ▸.
// - Image: Open Image in New Tab · Save Image As… · Capture Image… · Copy Image ·
//   Copy Image Address · Search Google for Image ‖ Inspect ‖ Services ▸.
// - Selection: Look Up "…" · Search Google for "…" · Copy · Copy Link to Highlight · Print… ‖
//   Inspect ‖ Speech ▸ ‖ Services ▸.
// - Editable field: Look Up "…" · Search Google for "…" ‖ Emoji & Symbols · Import Passwords ‖
//   Undo · Redo ‖ Cut · Copy · Paste · Paste and Match Style · Select All ‖ Print… ‖
//   Language Settings · Writing Direction ▸ ‖ Inspect ‖ Speech ▸ ‖ AutoFill ▸ ‖ Services ▸
//   (separators there inferred).
// - "Search Google" names the profile's search engine.
// - Extension (`chrome.contextMenus`) items appear in these menus; their place in Arc is unknown.
//   Here they go before the Inspect group, where Chrome puts them (inferred).
//
// Left out, with why (v1):
// - Cast…: Chromium's cast dialog is drawn by a Chrome browser window.
// - Search Google for Image: Chromium's image search needs a Chrome browser window (Lens).
// - Services ▸ and AutoFill ▸: added by macOS itself when it applies to the page's view; not built.
// - Copy, Copy Link to Highlight and Search on a link come only with a selection (Arc selects the
//   link's text on a right-click; Chromium on macOS does not).

/// What the shell does for an item it owns.
public enum PageMenuShellAction: Hashable, Sendable {
    case openLinkInSplitView(URL)
    case openLinkInLittleArc(URL)
    case openLinkInIncognito(URL)
    case captureImage
    case savePage
    case print
    case translate
    case search(String)
    case importPasswords

    /// The kind, for `PageContextMenuLayout.availableActions`.
    public var kind: Kind {
        switch self {
        case .openLinkInSplitView: .openLinkInSplitView
        case .openLinkInLittleArc: .openLinkInLittleArc
        case .openLinkInIncognito: .openLinkInIncognito
        case .captureImage: .captureImage
        case .savePage: .savePage
        case .print: .print
        case .translate: .translate
        case .search: .search
        case .importPasswords: .importPasswords
        }
    }

    public enum Kind: Hashable, Sendable, CaseIterable {
        case openLinkInSplitView, openLinkInLittleArc, openLinkInIncognito, captureImage, savePage, print
        case translate, search, importPasswords
    }
}

/// One row of the shown menu.
public enum PageMenuEntry: Hashable, Sendable {
    /// An engine item (run with `PageContextMenuSession.perform`), with its own title.
    case engine(PageContextMenuItem)
    /// An item the shell runs.
    case shell(PageMenuShellAction, title: String, isEnabled: Bool)
    case separator

    public var title: String? {
        switch self {
        case .engine(let item): item.title
        case .shell(_, let title, _): title
        case .separator: nil
        }
    }
}

public struct PageContextMenuLayout: Sendable {
    /// The profile's search engine name ("Google"). [05 §右键菜单] observed.
    public var searchEngineName: String
    /// The shell actions this window offers (a Little Arc window or Peek offers fewer).
    public var availableActions: Set<PageMenuShellAction.Kind>

    public init(searchEngineName: String, availableActions: Set<PageMenuShellAction.Kind> = Set(PageMenuShellAction.Kind.allCases)) {
        self.searchEngineName = searchEngineName
        self.availableActions = availableActions
    }

    /// Longest selection shown in a title before "…" (Chromium's limit for menu titles).
    public static let maxSelectionTitleLength = 50

    /// The menu rows for `menu`, in Arc's order. Never starts or ends with a separator and never
    /// has two in a row.
    public func entries(for menu: PageContextMenu) -> [PageMenuEntry] {
        let target = menu.target
        var groups: [[PageMenuEntry]]
        if target.isEditable {
            groups = editableGroups(menu)
        } else if target.isLink {
            groups = linkGroups(menu)
        } else if target.isImage {
            groups = imageGroups(menu)
        } else if target.hasSelection {
            groups = selectionGroups(menu)
        } else {
            groups = pageGroups(menu)
        }
        if [.video, .audio, .canvas, .plugin].contains(target.media) {
            // Chromium's media items (Loop, Show Controls, Picture in Picture…); Arc's are not in
            // the spec, so Chromium's order is kept.
            groups.insert(menu.items(.other).map(PageMenuEntry.engine), at: 0)
        }
        // Extensions before the developer group (Chrome's place; inferred).
        let extensions = menu.items(.extension).map(PageMenuEntry.engine)
        if let inspect = groups.firstIndex(where: { $0.contains { entry in
            if case .engine(let item) = entry { return item.role == .inspect }
            return false
        } }) {
            groups.insert(extensions, at: inspect)
        } else {
            groups.append(extensions)
        }
        return Self.joined(groups)
    }

    // MARK: Menus

    private func pageGroups(_ menu: PageContextMenu) -> [[PageMenuEntry]] {
        [
            engine(menu, .back, .forward, .reload),
            shell(.savePage, "Save As…") + printEntry(menu) + translateEntry(menu),
            engine(menu, .viewSource, .inspect),
        ]
    }

    private func linkGroups(_ menu: PageContextMenu) -> [[PageMenuEntry]] {
        guard let url = menu.target.linkURL else { return [] }
        var groups: [[PageMenuEntry]] = [
            engine(menu, .openLinkInNewTab, .openLinkInNewWindow)
                + shell(.openLinkInSplitView(url), "Open Link in Split View")
                + shell(.openLinkInLittleArc(url), "Open Link in Little Arc")
                + shell(.openLinkInIncognito(url), "Open Link in Incognito Window"),
            engine(menu, .saveLinkAs, .copyLinkAddress),
        ]
        if menu.target.isImage { groups.append(imageGroups(menu)[0]) }
        if menu.target.hasSelection {
            groups.append(engine(menu, .copy, .copyLinkToHighlight) + searchEntry(menu) + printEntry(menu))
        }
        groups.append(engine(menu, .inspect))
        groups.append(engine(menu, .speech))
        return groups
    }

    private func imageGroups(_ menu: PageContextMenu) -> [[PageMenuEntry]] {
        [
            engine(menu, .openImageInNewTab, .saveImageAs)
                + shell(.captureImage, "Capture Image…")
                + engine(menu, .copyImage, .copyImageAddress),
            engine(menu, .inspect),
        ]
    }

    private func selectionGroups(_ menu: PageContextMenu) -> [[PageMenuEntry]] {
        [
            engine(menu, .lookUp) + searchEntry(menu) + engine(menu, .copy, .copyLinkToHighlight) + printEntry(menu),
            engine(menu, .inspect),
            engine(menu, .speech),
        ]
    }

    private func editableGroups(_ menu: PageContextMenu) -> [[PageMenuEntry]] {
        [
            engine(menu, .spelling),
            engine(menu, .lookUp) + searchEntry(menu),
            engine(menu, .emoji) + shell(.importPasswords, "Import Passwords"),
            engine(menu, .undo, .redo),
            engine(menu, .cut, .copy, .paste, .pasteAndMatchStyle, .selectAll),
            printEntry(menu),
            engine(menu, .languageSettings, .writingDirection),
            engine(menu, .inspect),
            engine(menu, .speech),
        ]
    }

    // MARK: Pieces

    private func engine(_ menu: PageContextMenu, _ roles: PageContextMenuRole...) -> [PageMenuEntry] {
        roles.flatMap { menu.items($0) }.map(PageMenuEntry.engine)
    }

    private func shell(_ action: PageMenuShellAction, _ title: String, enabled: Bool = true) -> [PageMenuEntry] {
        availableActions.contains(action.kind) ? [.shell(action, title: title, isEnabled: enabled)] : []
    }

    /// Print…: the engine's item when it offers one (it prints just the image or the selection's
    /// frame), else the shell's File ▸ Print.
    private func printEntry(_ menu: PageContextMenu) -> [PageMenuEntry] {
        if let item = menu.item(.print) { return [.engine(item)] }
        return shell(.print, "Print…")
    }

    /// "Translate to <language>" with the engine's title, run by the shell's translation.
    private func translateEntry(_ menu: PageContextMenu) -> [PageMenuEntry] {
        guard let item = menu.item(.translate) else { return [] }
        return shell(.translate, item.title, enabled: item.isEnabled)
    }

    /// "Search <engine> for “…”" for the selection, with the profile's engine.
    private func searchEntry(_ menu: PageContextMenu) -> [PageMenuEntry] {
        let text = menu.target.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !menu.target.isPasswordField else { return [] }
        return shell(.search(text), "Search \(searchEngineName) for “\(Self.shortened(text))”")
    }

    /// `text` on one line, cut at `maxSelectionTitleLength` with "…".
    static func shortened(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard line.count > maxSelectionTitleLength else { return line }
        return String(line.prefix(maxSelectionTitleLength)) + "…"
    }

    private static func joined(_ groups: [[PageMenuEntry]]) -> [PageMenuEntry] {
        var result: [PageMenuEntry] = []
        for group in groups where !group.isEmpty {
            if !result.isEmpty { result.append(.separator) }
            result += group
        }
        return result
    }
}
