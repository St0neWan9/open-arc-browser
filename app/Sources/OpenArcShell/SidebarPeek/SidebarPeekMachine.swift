import Foundation

// Hidden-sidebar peek: the pure state machine. [06 §14] observed: with the sidebar hidden, the
// pointer at the window's left edge slides the sidebar out as a floating overlay after a ≈ 0.11 s
// dwell [07 §11]; it stays while the pointer is inside, starts to collapse as soon as the pointer
// leaves to the page ([07 §11] observed, no delay), and "Lock
// sidebar" pins it back. Time is passed in (`now`), so tests drive it with a fake clock.

/// How the sidebar is on screen.
public enum SidebarPresentation: Equatable, Sendable {
    /// In the window layout, next to the web panel (the normal state).
    case pinned
    /// Gone: the web panel fills the window. [06 §14] observed.
    case hidden
    /// Floating over the web panel after the pointer touched the left edge. [06 §14] observed.
    case peeking

    /// Accessibility label (and tooltip) of the sidebar button in the top bar. [06 §14] observed:
    /// "Hide sidebar" while pinned, "Lock sidebar" inside the floating overlay. While hidden the
    /// button is not on screen; the pinned wording is returned.
    public var sidebarButtonLabel: String {
        self == .peeking ? "Lock sidebar" : "Hide sidebar"
    }

    /// Whether the standard window buttons ("traffic lights") show. [06 §14] observed: they go
    /// away with the sidebar and come back inside the overlay.
    public var showsWindowButtons: Bool { self != .hidden }
}

/// Where the pointer is, as far as the peek cares.
enum SidebarPeekPointerRegion: Equatable, Sendable {
    /// The thin hot zone at the window's left edge. [06 §14] observed (x ≈ 0–2 pt).
    case edge
    /// Over the floating overlay (or a window it opened, e.g. a folder's quick list).
    case overlay
    /// Anywhere else: the web panel, or outside the window.
    case outside
}

/// Delays of the peek: `Motion.sidebarPeekOpenDwell` / `sidebarPeekCloseDelay` ([07 §11] observed).
struct SidebarPeekTiming: Equatable, Sendable {
    /// Time the pointer must rest in the edge zone before the overlay opens.
    var openDelay: TimeInterval
    /// Time after the pointer left the overlay before it collapses.
    var closeDelay: TimeInterval

    static let standard = SidebarPeekTiming(openDelay: SidebarPeekTokens.openDelay, closeDelay: SidebarPeekTokens.closeDelay)
}

/// The peek state machine: pinned / hidden / peeking, plus one pending deadline (open while the
/// pointer rests at the edge, close while it is away from the overlay).
struct SidebarPeekMachine: Equatable, Sendable {
    private(set) var presentation: SidebarPresentation
    /// When the pending change happens; nil when nothing is pending.
    private(set) var deadline: Date?
    var timing: SidebarPeekTiming

    init(isPinned: Bool, timing: SidebarPeekTiming = .standard) {
        self.presentation = isPinned ? .pinned : .hidden
        self.timing = timing
    }

    /// The sidebar was hidden (⌘S, View menu, the sidebar button while pinned).
    mutating func hide() {
        presentation = .hidden
        deadline = nil
    }

    /// The sidebar was shown: from the menu, or "Lock sidebar" in the overlay. [06 §14] observed.
    mutating func pin() {
        presentation = .pinned
        deadline = nil
    }

    /// The pointer moved to `region` at `now`.
    mutating func pointer(_ region: SidebarPeekPointerRegion, now: Date) {
        switch presentation {
        case .pinned:
            return
        case .hidden:
            guard region == .edge else {
                // Left the edge before the overlay opened: cancel.
                deadline = nil
                return
            }
            if deadline == nil {
                deadline = now.addingTimeInterval(timing.openDelay)
                tick(now: now)
            }
        case .peeking:
            switch region {
            case .edge, .overlay:
                deadline = nil
            case .outside:
                if deadline == nil {
                    deadline = now.addingTimeInterval(timing.closeDelay)
                    tick(now: now)
                }
            }
        }
    }

    /// Applies the pending change once its deadline has passed. Returns whether anything changed.
    @discardableResult
    mutating func tick(now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        switch presentation {
        case .hidden: presentation = .peeking
        case .peeking: presentation = .hidden
        case .pinned: return false
        }
        return true
    }
}
