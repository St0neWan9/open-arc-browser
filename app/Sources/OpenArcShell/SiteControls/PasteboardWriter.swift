import Foundation
import AppKit

// Writes links to the pasteboard. Injected so tests never touch the system pasteboard.

@MainActor
public protocol PasteboardWriter: AnyObject {
    func writeURL(_ url: URL)
}

/// The general system pasteboard (same format as the tab menu's Copy Link).
@MainActor
public final class SystemPasteboardWriter: PasteboardWriter {
    public init() {}
    public func writeURL(_ url: URL) { SidebarPasteboard.copy(url) }
}

/// Records writes instead of touching the pasteboard (tests, previews).
@MainActor
public final class RecordingPasteboardWriter: PasteboardWriter {
    public private(set) var written: [URL] = []
    public init() {}
    public func writeURL(_ url: URL) { written.append(url) }
}
