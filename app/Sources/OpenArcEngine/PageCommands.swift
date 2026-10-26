import Foundation

// Value types of the page commands on `BrowserTab` (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §4):
// find in page, edit commands, DevTools panels, zoom presets. Menu items: [01 §Edit] Find ▸,
// Undo…Select All; [01 §View] Zoom to Actual Size / Zoom In / Zoom Out, Developer ▸; [01 §File]
// Print, Save Page As (all observed item names). Bridge: `OACFindOptions`, `-findString:options:`,
// `-performEditCommand:`, `-showDevToolsWithPanel:` (OACTab.h).

/// Options of one find request (`OACFindOptions`).
public struct FindOptions: Hashable, Sendable {
    /// Search backwards (Find Previous).
    public var backwards: Bool
    /// Case sensitive.
    public var matchCase: Bool
    /// Continue from the current match (Find Next / Previous); false starts a new search.
    public var findNext: Bool

    public init(backwards: Bool = false, matchCase: Bool = false, findNext: Bool = false) {
        self.backwards = backwards
        self.matchCase = matchCase
        self.findNext = findNext
    }
}

/// Result of the current find-in-page search (`TabEvent.findResultChanged`).
public struct FindResult: Hashable, Sendable {
    /// Number of matches found so far.
    public var matches: Int
    /// 1-based ordinal of the active match; 0 when there is none.
    public var activeOrdinal: Int
    /// The whole page was searched (`matches` is final).
    public var isFinal: Bool

    public init(matches: Int, activeOrdinal: Int, isFinal: Bool) {
        self.matches = matches
        self.activeOrdinal = activeOrdinal
        self.isFinal = isFinal
    }

    public static let none = FindResult(matches: 0, activeOrdinal: 0, isFinal: true)
}

/// Edit menu commands on the focused frame. [01 §Edit] observed items.
public enum EditCommand: String, CaseIterable, Hashable, Sendable {
    case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
}

/// DevTools panels reachable from View ▸ Developer ▸ ([01 §View] observed: Developer Tools,
/// Inspect Elements, JavaScript Console, Network Inspector).
public enum DevToolsPanel: String, Hashable, Sendable {
    case elements, console, network
}

/// Zoom levels shared by every engine (Chromium's preset list). Zoom In / Out step through them.
public enum ZoomLevels {
    public static let presets: [Double] = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
    public static let range: ClosedRange<Double> = 0.25...5

    /// The next preset above `factor` (or the largest).
    public static func next(after factor: Double) -> Double {
        presets.first { $0 > factor + 0.0001 } ?? presets[presets.count - 1]
    }

    /// The next preset below `factor` (or the smallest).
    public static func next(before factor: Double) -> Double {
        presets.last { $0 < factor - 0.0001 } ?? presets[0]
    }

    /// Whole percent for display ("110%").
    public static func percent(_ factor: Double) -> Int { Int((factor * 100).rounded()) }
}
