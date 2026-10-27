import Foundation
import AppKit

// Writes links to the pasteboard. Injected so tests never touch the system pasteboard.

@MainActor
public protocol PasteboardWriter: AnyObject {
    func writeURL(_ url: URL)
    /// Plain text (Edit ▸ Copy URL as Markdown, B62).
    func writeText(_ text: String)
}

/// The general system pasteboard (same format as the tab menu's Copy Link).
@MainActor
public final class SystemPasteboardWriter: PasteboardWriter {
    public init() {}
    public func writeURL(_ url: URL) { SidebarPasteboard.copy(url) }
    public func writeText(_ text: String) { SidebarPasteboard.copyText(text) }
}

/// Records writes instead of touching the pasteboard (tests, previews).
@MainActor
public final class RecordingPasteboardWriter: PasteboardWriter {
    public private(set) var written: [URL] = []
    public private(set) var writtenText: [String] = []
    public init() {}
    public func writeURL(_ url: URL) { written.append(url) }
    public func writeText(_ text: String) { writtenText.append(text) }
}
