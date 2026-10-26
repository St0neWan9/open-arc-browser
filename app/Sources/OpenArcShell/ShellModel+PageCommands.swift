import Foundation
import OpenArcEngine

// Page commands of the window's selected tab (plan C7b, chromium-bridge/SWIFT_PROTOCOL_CHANGES.md
// §4). Menu items: [01 §View] observed "Refresh the Page", "Force Refresh the Page", "Zoom to
// Actual Size", "Zoom In", "Zoom Out"; keys [02] observed ⌘R / ⇧⌘R, ⌘+ / ⌘- / ⌘0.
// In a split the selected tab is the focused pane, so the commands act on that pane (inferred).

extension ShellModel {
    /// The selected tab's live state, for menu enablement.
    var selectedPageState: SidebarTabLiveState? { sidebar.selectedLiveState }

    /// The crash page of tab `tabID`'s panel, while its renderer is gone (C9); nil otherwise.
    func crashedPageState(for tabID: UUID?) -> CrashedPageState? {
        guard let tabID, sidebar.liveState(for: tabID)?.isCrashed == true else { return nil }
        return CrashedPageState(reload: { [weak self] in self?.reloadCrashedPage(tabID) })
    }

    /// The crash page's Reload: reloads tab `tabID` in a new renderer (C9, own design).
    public func reloadCrashedPage(_ tabID: UUID) {
        guard let live = sidebar.liveTab(for: tabID) else { return }
        controller.enqueueTabCommand(live) { try? await $0.reload() }
    }

    /// View ▸ Force Refresh the Page (⇧⌘R): reload bypassing the cache.
    public func forceReload() {
        runOnSelectedPage { try await $0.reload(bypassingCache: true) }
    }

    /// View ▸ Zoom In (⌘+).
    public func zoomIn() { runOnSelectedPage { await $0.zoomIn() } }

    /// View ▸ Zoom Out (⌘-).
    public func zoomOut() { runOnSelectedPage { await $0.zoomOut() } }

    /// View ▸ Zoom to Actual Size (⌘0).
    public func resetZoom() { runOnSelectedPage { await $0.resetZoom() } }

    /// Zoom In / Out are disabled at the ends of the zoom range (inferred).
    var canZoomIn: Bool { selectedLiveTab != nil && (selectedPageState?.zoomFactor ?? 1) < ZoomLevels.range.upperBound }
    var canZoomOut: Bool { selectedLiveTab != nil && (selectedPageState?.zoomFactor ?? 1) > ZoomLevels.range.lowerBound }
    /// Zoom to Actual Size is enabled only when the page is zoomed (inferred).
    var canResetZoom: Bool { selectedLiveTab != nil && (selectedPageState?.zoomFactor ?? 1) != 1 }

    /// Runs `body` on the selected tab's engine tab, in issue order per tab (`enqueueTabCommand`).
    private func runOnSelectedPage(_ body: @escaping @Sendable (any BrowserTab) async throws -> Void) {
        guard let live = selectedLiveTab else { return }
        controller.enqueueTabCommand(live) { try? await body($0) }
    }
}
