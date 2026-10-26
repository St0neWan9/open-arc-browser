import Foundation

/// Reads the Netscape bookmark HTML file that Safari, Firefox and the Chromium family write with
/// "Export Bookmarks". The format is old and loose:
///
/// ```html
/// <!DOCTYPE NETSCAPE-Bookmark-file-1>
/// <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
/// <DL><p>
///     <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
///     <DL><p>
///         <DT><A HREF="https://example.com/" ADD_DATE="…">Example</A>
///     </DL><p>
///     <DT><A HREF="…">Loose bookmark</A>
///     <DD>An optional description
/// </DL><p>
/// ```
///
/// `<DT>`, `<DD>` and `<p>` are never closed, tag names may be any case, and text and attribute
/// values use HTML entities. A folder is an `<H3>` whose children are the `<DL>` that follows; an
/// `<H3>` with no `<DL>` after it is an empty folder (kept). Descriptions (`<DD>`) are ignored.
///
/// Mapping (inferred, D3): the top-level folder marked `PERSONAL_TOOLBAR_FOLDER` (Chrome, Firefox)
/// is the bookmark bar. Without that mark, a top-level folder titled like a bar ("Favorites",
/// "Favorites Bar", "Bookmarks Bar", "Bookmarks Toolbar"; Safari writes "Favorites") is used.
/// Every other top-level item goes to `other`. A file with no bar at all puts everything in `bar`,
/// so a plain list of links lands as pinned items rather than inside one folder.
public enum NetscapeBookmarksParser {
    public static func parse(_ data: Data) throws -> BookmarkTree {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw BookmarkImportError.unreadable("not text")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> BookmarkTree {
        guard looksLikeNetscape(text) else { throw BookmarkImportError.unrecognizedFormat }
        var builder = Builder()
        for token in Tokenizer(text) { builder.consume(token) }
        let top = builder.finish()
        return split(top)
    }

    /// Whether `text` is a Netscape bookmark file (its doctype, or a `<DL>` list with links).
    static func looksLikeNetscape(_ text: String) -> Bool {
        let head = text.prefix(4096).uppercased()
        if head.contains("NETSCAPE-BOOKMARK-FILE") { return true }
        let upper = text.uppercased()
        return upper.contains("<DL") && (upper.contains("<DT") || upper.contains("<A "))
    }

    // MARK: Top-level split

    private static let barTitles: Set<String> = ["favorites", "favourites", "favorites bar", "favourites bar", "bookmarks bar", "bookmarks toolbar"]

    private static func split(_ top: [Parsed]) -> BookmarkTree {
        var barIndex = top.firstIndex { if case .folder(_, true, _) = $0 { return true } else { return false } }
        if barIndex == nil {
            barIndex = top.firstIndex {
                if case .folder(let title, _, _) = $0 { return barTitles.contains(title.lowercased()) }
                return false
            }
        }
        guard let barIndex, case .folder(_, _, let barChildren) = top[barIndex] else {
            return BookmarkTree(bar: top.map(\.node), other: [])
        }
        var other = top
        other.remove(at: barIndex)
        return BookmarkTree(bar: barChildren.map(\.node), other: other.map(\.node))
    }

    // MARK: Tree building

    /// A parsed node that still knows whether it was the toolbar folder.
    indirect enum Parsed {
        case bookmark(Bookmark)
        case folder(title: String, isToolbar: Bool, children: [Parsed])

        var node: BookmarkNode {
            switch self {
            case .bookmark(let bookmark): return .bookmark(bookmark)
            case .folder(let title, _, let children): return .folder(BookmarkFolder(title: title, children: children.map(\.node)))
            }
        }
    }

    /// One open `<DL>`. `folder` is nil for a list without a heading (the file's outer list): its
    /// children belong to the enclosing list.
    private struct Frame {
        var folder: (title: String, isToolbar: Bool)?
        var children: [Parsed] = []
    }

    /// What text is being collected for.
    private enum Capture {
        case none
        case heading(isToolbar: Bool, text: String)
        case link(href: String, text: String)
    }

    private struct Builder {
        /// `frames[0]` is the document itself and is never popped.
        var frames: [Frame] = [Frame()]
        var capture: Capture = .none
        /// A heading that ended and waits for its `<DL>`.
        var pendingFolder: (title: String, isToolbar: Bool)?

        mutating func consume(_ token: Token) {
            switch token {
            case .text(let raw):
                switch capture {
                case .none: break
                case .heading(let toolbar, let text): capture = .heading(isToolbar: toolbar, text: text + raw)
                case .link(let href, let text): capture = .link(href: href, text: text + raw)
                }
            case .open(let name, let attributes):
                switch name {
                case "H3":
                    endCapture()
                    flushPendingFolder()
                    let toolbar = attributes["PERSONAL_TOOLBAR_FOLDER"]?.lowercased() == "true"
                    capture = .heading(isToolbar: toolbar, text: "")
                case "A":
                    endCapture()
                    flushPendingFolder()
                    capture = .link(href: attributes["HREF"] ?? "", text: "")
                case "DL":
                    endCapture()
                    frames.append(Frame(folder: pendingFolder))
                    pendingFolder = nil
                case "DT", "DD":
                    endCapture()
                    flushPendingFolder()
                default:
                    break
                }
            case .close(let name):
                switch name {
                case "H3", "A":
                    endCapture()
                case "DL":
                    endCapture()
                    flushPendingFolder()
                    popFrame()
                default:
                    break
                }
            }
        }

        /// Closes every list left open and returns the document's top-level items.
        mutating func finish() -> [Parsed] {
            endCapture()
            flushPendingFolder()
            while frames.count > 1 { popFrame() }
            return frames[0].children
        }

        private mutating func endCapture() {
            switch capture {
            case .none:
                return
            case .heading(let toolbar, let text):
                // A heading waits for the `<DL>` that holds its children.
                flushPendingFolder()
                pendingFolder = (NetscapeBookmarksParser.clean(text), toolbar)
            case .link(let href, let text):
                append(.bookmark(Bookmark(title: NetscapeBookmarksParser.clean(text), url: href.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            capture = .none
        }

        /// A heading followed by something other than `<DL>` is an empty folder.
        private mutating func flushPendingFolder() {
            guard let folder = pendingFolder else { return }
            pendingFolder = nil
            append(.folder(title: folder.title, isToolbar: folder.isToolbar, children: []))
        }

        private mutating func append(_ node: Parsed) {
            frames[frames.count - 1].children.append(node)
        }

        private mutating func popFrame() {
            guard frames.count > 1, let frame = frames.popLast() else { return }
            if let folder = frame.folder {
                append(.folder(title: folder.title, isToolbar: folder.isToolbar, children: frame.children))
            } else {
                frames[frames.count - 1].children.append(contentsOf: frame.children)
            }
        }
    }

    /// Collapses whitespace and trims.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Tokens

    enum Token: Equatable {
        case text(String)
        /// Upper-cased tag name and attributes (upper-cased names, decoded values).
        case open(String, [String: String])
        case close(String)
    }

    /// Splits the file into tags and decoded text. Comments, doctype and processing instructions
    /// are dropped.
    struct Tokenizer: Sequence, IteratorProtocol {
        private let scalars: [Character]
        private var index = 0

        init(_ text: String) { scalars = Array(text) }

        mutating func next() -> Token? {
            while index < scalars.count {
                if scalars[index] == "<" {
                    if let token = readTag() { return token }
                    continue
                }
                let start = index
                while index < scalars.count, scalars[index] != "<" { index += 1 }
                return .text(HTMLEntities.decode(String(scalars[start..<index])))
            }
            return nil
        }

        /// Reads one tag starting at `<`. Returns nil for a comment or declaration (skipped).
        private mutating func readTag() -> Token? {
            if starts(with: "<!--") {
                index += 4
                while index < scalars.count, !starts(with: "-->") { index += 1 }
                index = Swift.min(index + 3, scalars.count)
                return nil
            }
            let start = index + 1
            var end = start
            var quote: Character?
            while end < scalars.count {
                let c = scalars[end]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    break
                }
                end += 1
            }
            index = Swift.min(end + 1, scalars.count)
            let body = String(scalars[start..<Swift.min(end, scalars.count)])
            if body.hasPrefix("!") || body.hasPrefix("?") { return nil }
            if body.hasPrefix("/") {
                return .close(Self.name(in: body.dropFirst()))
            }
            let name = Self.name(in: Substring(body))
            if name.isEmpty { return .text("<") }
            return .open(name, Self.attributes(in: body.dropFirst(name.count)))
        }

        private func starts(with prefix: String) -> Bool {
            var i = index
            for c in prefix {
                guard i < scalars.count, scalars[i] == c else { return false }
                i += 1
            }
            return true
        }

        private static func name(in body: Substring) -> String {
            String(body.prefix { $0.isLetter || $0.isNumber }).uppercased()
        }

        /// Attributes as `NAME="value"`, `NAME='value'`, `NAME=value` or a bare `NAME`.
        static func attributes(in text: Substring) -> [String: String] {
            var result: [String: String] = [:]
            var rest = text[...]
            while true {
                rest = rest.drop { $0.isWhitespace || $0 == "/" }
                guard !rest.isEmpty else { break }
                let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != ">" }
                guard !name.isEmpty else { rest = rest.dropFirst(); continue }
                rest = rest.dropFirst(name.count).drop { $0.isWhitespace }
                var value = ""
                if rest.first == "=" {
                    rest = rest.dropFirst().drop { $0.isWhitespace }
                    if let q = rest.first, q == "\"" || q == "'" {
                        let inner = rest.dropFirst()
                        let raw = inner.prefix { $0 != q }
                        value = String(raw)
                        rest = inner.dropFirst(raw.count).dropFirst()
                    } else {
                        let raw = rest.prefix { !$0.isWhitespace }
                        value = String(raw)
                        rest = rest.dropFirst(raw.count)
                    }
                }
                result[name.uppercased()] = HTMLEntities.decode(value)
            }
            return result
        }
    }
}

/// Decodes the HTML entities found in bookmark exports: the named XML ones, `&nbsp;`, and numeric
/// references. Unknown names are left as written.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";"), let decoded = entity(String(after[..<semi])) {
                out += decoded
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }

    private static func entity(_ name: String) -> String? {
        if let value = named[name.lowercased()] { return value }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let code: UInt32?
        if digits.first == "x" || digits.first == "X" {
            code = UInt32(digits.dropFirst(), radix: 16)
        } else {
            code = UInt32(digits, radix: 10)
        }
        return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
