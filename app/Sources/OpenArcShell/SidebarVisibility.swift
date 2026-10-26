import SwiftUI

// Sidebar hide/show: the animation token and the view-facing state derived from `ShellModel`.
// [01 §View] observed: the View menu has "Hide Sidebar". [00 §sidebar] says the collapse
// animation was not measured, so the timing below is a local placeholder.

enum ShellLocalTokens {
    /// Duration of the sidebar slide-out/in while the web panel resizes. unknown (not measured);
    /// kept short on purpose.
    static let sidebarToggleDuration: Double = 0.25

    /// Curve of the sidebar slide. unknown (not measured).
    static var sidebarToggleAnimation: Animation { .easeInOut(duration: sidebarToggleDuration) }

    /// Soft shadow around the web panel. Round-1 comparison (B32) observed: the window is ≈ 7 %
    /// darker right above the panel, ≈ 11 % at its left and ≈ 13 % below it, fading within
    /// ≈ 3–6 pt; black ≈ 18 %, radius 3, y + 1 reproduce it (inferred fit).
    static let webPanelShadowOpacity: Double = 0.18
    static let webPanelShadowRadius: CGFloat = 3
    static let webPanelShadowOffsetY: CGFloat = 1
}

extension ShellModel {
    /// Title of the View menu item. [01 §View] observed "Hide Sidebar"; the "Show Sidebar" wording
    /// while hidden is inferred (the spec only records the visible-state title).
    var sidebarToggleTitle: String { isSidebarVisible ? "Hide Sidebar" : "Show Sidebar" }

    /// Whether the left column is on screen. The Create Space view lives in that column, so it
    /// forces the column open even while the sidebar is hidden. inferred.
    var showsSidebarColumn: Bool { isSidebarVisible || spaceFlow.isCreating }

    /// pinned / hidden / floating (peek). [06 §14] observed. B34.
    var sidebarPresentation: SidebarPresentation { sidebarPeek.presentation }

    /// Whether the floating sidebar is drawn over the web panel. Not while the Create Space view
    /// holds the column or the Library fills the window. inferred.
    var showsSidebarPeek: Bool {
        sidebarPresentation == .peeking && !spaceFlow.isCreating && !library.isActive
    }

    /// Whether the window tracks the pointer for the left-edge peek: only while hidden. B34.
    var tracksSidebarPeek: Bool { !isSidebarVisible && !spaceFlow.isCreating && !library.isActive }

    /// Whether the traffic lights show. [06 §14] observed: they go away with the hidden sidebar
    /// and come back inside the floating panel. The Library and the Create Space column draw
    /// their own top bar, so they keep them (inferred).
    var showsWindowButtons: Bool {
        sidebarPresentation.showsWindowButtons || spaceFlow.isCreating || library.isActive
    }

    /// Frames of the window. The floating sidebar does not take part: the web panel keeps its
    /// hidden-state frame while it is out. [06 §14] observed.
    func windowLayout(size: CGSize) -> MainWindowLayout {
        MainWindowLayout(windowSize: size, isSidebarVisible: showsSidebarColumn)
    }
}
