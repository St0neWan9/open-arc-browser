import SwiftUI
import OpenArcDesign

// Sidebar hide/show: the view-facing state derived from `ShellModel`. [01 §View] observed: the
// View menu has "Hide Sidebar". The ⌘S animation is `ShellMotion.sidebarToggle`
// (`Motion.sidebarToggle`, [07 §11] inferred curve over observed frames).

extension View {
    /// The edge shadow of a web content surface (main panel, split pane, Little Arc page, Library
    /// content), per appearance. Apply after the surface's rounded clip so the shadow follows the
    /// corner. Values: `Metrics.WebPanel.shadow`, [07 §7.1].
    func webPanelEdgeShadow(_ appearance: ResolvedAppearance) -> some View {
        let s = Metrics.WebPanel.shadow(appearance)
        return shadow(color: .black.opacity(s.opacity), radius: s.radius, x: s.offsetX, y: s.offsetY)
    }
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
