import Foundation
import AppKit
import OpenArcPersistence

// Links, local help pages and desktop services behind the menu bar's app and help items (plan
// B72). [01 §Arc] observed: Share Arc, Privacy Policy; [01 §Help] observed: Getting Started,
// Essential Keyboard Shortcuts, Contact the Team, Visit Help Center, Troubleshooting ▸.

/// The project's public pages, all built from one site address (plan B88). The product's final
/// name and domain are not decided yet, so `siteHost` is a placeholder on the reserved `.example`
/// domain, which keeps a click from reaching anyone's real site. Replace `siteHost` (and only it)
/// when the project site exists; no other file may spell out a URL to these pages
/// (`AppLinksTests` checks the sources). The appcast (`UpdateConfiguration.placeholderFeedURL`)
/// and the ad-block manifest (`AdBlockRulesetUpdateConfiguration`) are feeds, not pages, and keep
/// their own static-host placeholders.
public enum OpenArcLinks {
    /// The project site's host. Placeholder until the site exists.
    public static let siteHost = "openarc.example"
    /// The site's root.
    public static let site = URL(string: "https://\(siteHost)/")!

    /// What Arc ▸ Share Open Arc shares ([01 §Arc] observed item "Share Arc").
    public static let homepage = site
    /// Arc ▸ Privacy Policy ([01 §Arc] observed item).
    public static let privacyPolicy = page("privacy")
    /// Help ▸ Visit Help Center ([01 §Help] observed item).
    public static let helpCenter = page("help")
    /// Settings ▸ Profiles "Learn more" (plan B83; inferred target: our help page on profiles).
    public static let profilesHelp = page("help/profiles")
    /// Help ▸ Contact the Team ([01 §Help] observed item) and the command bar row of that name.
    public static let contactTheTeam = URL(string: "mailto:team@\(siteHost)")!

    /// Every link above, for checks that all shipped links come from here.
    public static let all: [URL] = [homepage, privacyPolicy, helpCenter, profilesHelp, contactTheTeam]

    private static func page(_ path: String) -> URL {
        site.appendingPathComponent(path, isDirectory: false)
    }
}

/// What the app asks of the desktop: open a link in its default app, show a file in Finder, show
/// the share picker, put text on the pasteboard. Injected through `AppDependencies`, so tests and
/// previews never open Mail or Finder or show a picker.
@MainActor
public protocol DesktopServices: AnyObject, Sendable {
    /// Opens `url` in its default app (a `mailto:` link opens the mail app).
    func open(_ url: URL)
    /// Selects a file or folder in Finder.
    func reveal(_ url: URL)
    /// Shows the system share picker for `items`. Returns false when there is no window for it.
    @discardableResult
    func share(_ items: [URL]) -> Bool
    /// Writes plain text to the general pasteboard.
    func copyText(_ text: String)
}

/// The real desktop (the app passes this; `AppDependencies.live`).
@MainActor
public final class SystemDesktopServices: DesktopServices {
    public nonisolated init() {}

    public func open(_ url: URL) { NSWorkspace.shared.open(url) }

    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// The share picker hangs from the top center of the key window's content (inferred: where
    /// Arc shows the menu bar's share picker was not recorded).
    public func share(_ items: [URL]) -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
        guard let view = window?.contentView, !items.isEmpty else { return false }
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY - 2
        let anchor = NSRect(x: view.bounds.midX - 1, y: top, width: 2, height: 2)
        NSSharingServicePicker(items: items).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        return true
    }

    public func copyText(_ text: String) { SidebarPasteboard.copyText(text) }
}

/// Records every request instead of acting (the default: tests, previews).
@MainActor
public final class RecordingDesktopServices: DesktopServices {
    public private(set) var opened: [URL] = []
    public private(set) var revealed: [URL] = []
    public private(set) var shared: [[URL]] = []
    public private(set) var copiedText: [String] = []

    public nonisolated init() {}

    public func open(_ url: URL) { opened.append(url) }
    public func reveal(_ url: URL) { revealed.append(url) }
    public func share(_ items: [URL]) -> Bool {
        shared.append(items)
        return true
    }
    public func copyText(_ text: String) { copiedText.append(text) }
}

/// Help ▸ Getting Started and Help ▸ Essential Keyboard Shortcuts are web pages in Arc
/// ([06 §27.5] observed: Getting Started opens a page in a new tab at the top of Today; [02 §其他]
/// observed: the shortcuts item opens a page). Ours are local pages with our own text and layout
/// ([06 §27.5] inferred: "make it our own local page; Arc's layout is reference only").
enum HelpPages {
    enum Page: String, CaseIterable {
        case gettingStarted = "getting-started"
        case keyboardShortcuts = "keyboard-shortcuts"

        /// The opened tab's title until the page loads ([06 §27.5] observed row "Getting Started").
        var title: String {
            switch self {
            case .gettingStarted: return "Getting Started"
            case .keyboardShortcuts: return "Essential Keyboard Shortcuts"
            }
        }

        var fileName: String { rawValue + ".html" }
    }

    /// Writes every page into `directory` (created if needed) and returns the file URL of `page`.
    /// The pages are rewritten each time, so they always list the running build's shortcuts.
    static func write(_ page: Page, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for each in Page.allCases {
            try Data(html(each).utf8).write(to: directory.appendingPathComponent(each.fileName), options: .atomic)
        }
        return directory.appendingPathComponent(page.fileName)
    }

    /// `<app data dir>/Help`, or a folder in the temporary directory without persistence.
    static func directory(dataDirectory: URL?) -> URL {
        let base = dataDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        return base.appendingPathComponent("Help", isDirectory: true)
    }

    static func html(_ page: Page) -> String {
        switch page {
        case .gettingStarted: return gettingStartedHTML
        case .keyboardShortcuts: return shortcutsHTML(ShortcutCatalog.groups)
        }
    }

    private static var gettingStartedHTML: String {
        let cards: [(String, String)] = [
            ("Keep the tabs you use", "Press ⌘D to pin a tab. Pinned tabs stay at the top of the sidebar; the tabs under the line tidy themselves away after a while."),
            ("A Space for each part of your day", "Make a Space for work, one for home, one for a project, and move between them with ⌃1…⌃9."),
            ("Two pages side by side", "Add Split View with ⌃⇧= to read one page while you write in another."),
            ("Open a tab", "Press ⌘T, then type an address or what you are looking for."),
        ]
        let sections = cards.enumerated().map { index, card in
            "<section><span class=\"n\">\(index + 1)</span><h2>\(escape(card.0))</h2><p>\(escape(card.1))</p></section>"
        }.joined(separator: "\n")
        return document(title: Page.gettingStarted.title, body: """
        <h1>Welcome to \(escape(AppIdentity.displayName))</h1>
        <p class="lead">A few basics to get going.</p>
        \(sections)
        <p class="links"><a href="\(Page.keyboardShortcuts.fileName)">\(escape(Page.keyboardShortcuts.title))</a> · <a href="\(OpenArcLinks.helpCenter.absoluteString)">Help Center</a></p>
        """)
    }

    static func shortcutsHTML(_ groups: [ShortcutGroup]) -> String {
        let tables = groups.map { group in
            let rows = group.entries.map { "<tr><td>\(escape($0.action))</td><td class=\"k\">\(escape($0.keys))</td></tr>" }.joined()
            return "<h2>\(escape(group.title))</h2><table>\(rows)</table>"
        }.joined(separator: "\n")
        return document(title: Page.keyboardShortcuts.title, body: "<h1>\(escape(Page.keyboardShortcuts.title))</h1>\n\(tables)")
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px -apple-system, system-ui, sans-serif; max-width: 640px; margin: 48px auto; padding: 0 24px; line-height: 1.5; }
        h1 { font-size: 30px; margin-bottom: 4px; } .lead { opacity: 0.6; margin-top: 0; }
        section { border-radius: 14px; padding: 14px 18px; margin: 12px 0; background: rgba(127, 127, 127, 0.12); }
        section h2 { font-size: 16px; margin: 0 0 4px; } section p { margin: 0; }
        .n { float: right; opacity: 0.5; font-weight: 600; }
        table { width: 100%; border-collapse: collapse; } td { padding: 6px 0; border-bottom: 1px solid rgba(127, 127, 127, 0.2); }
        td.k { text-align: right; font-family: ui-monospace, monospace; } .links { margin-top: 24px; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Help ▸ Troubleshooting ▸ Copy Open Arc Info ([01 §Help] observed item "Copy Arc Info"; what it
/// copies is ours, inferred): what a bug report needs, one fact per line.
enum AppDiagnostics {
    static func info(engineVersion: String, bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let os = processInfo.operatingSystemVersion
        return [
            "\(AppIdentity.displayName) \(version) (\(build))",
            "Bundle: \(AppIdentity.bundleIdentifier)",
            "Engine: \(engineVersion)",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ].joined(separator: "\n")
    }
}

/// Edit ▸ Copy URL as Quote (⌃⇧⌘C, [01 §Edit], [02 §复制链接] observed item and key). The spec
/// records no format; ours (inferred) is a Markdown quote of the page's selection followed by a
/// link to the page that jumps to that text (a text fragment, `#:~:text=`). Without a selection it
/// is a quote line with the page title.
enum QuoteLink {
    /// Selections longer than this many words link by their first and last words (`start,end`).
    static let maxDirectWords = 8
    static let edgeWords = 4

    static func text(selection: String, title: String, url: URL) -> String {
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title.isEmpty ? (url.host ?? url.absoluteString) : title)
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        guard !quote.isEmpty else { return "> [\(name)](\(url.absoluteString))" }
        let lines = quote.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> \($0)" }
        let link = fragmentURL(url, quoting: quote) ?? url
        return (lines + [">", "> — [\(name)](\(link.absoluteString))"]).joined(separator: "\n")
    }

    /// `url` with a text directive for `quote` appended to its fragment.
    static func fragmentURL(_ url: URL, quoting quote: String) -> URL? {
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let directive: String
        if words.count > maxDirectWords {
            directive = encode(words.prefix(edgeWords).joined(separator: " ")) + "," + encode(words.suffix(edgeWords).joined(separator: " "))
        } else {
            directive = encode(words.joined(separator: " "))
        }
        components.percentEncodedFragment = (components.percentEncodedFragment ?? "") + ":~:text=" + directive
        return components.url
    }

    /// Percent-encodes a text directive part; `-`, `,` and `&` are reserved in it.
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "-,&#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
