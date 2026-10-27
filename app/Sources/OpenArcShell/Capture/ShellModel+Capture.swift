import Foundation
import CoreGraphics
import OpenArcDesign

// Entry points of the capture tools (plan B51): File ▸ Capture… (⇧⌘2) · Capture Full Page ·
// Capture in Portrait Mode ([01 §File], [02] observed) and the Site Control Center's camera and
// full page buttons ([06 §12], [06 §24] observed). Share and New Boost, the other two buttons,
// have no surface yet and stay where `toolHandler` left them.

extension ShellModel {
    /// File ▸ Capture… and the Site Control Center's camera button. [06 §24.1] observed.
    public func beginRegionCapture() { pageCapture.beginRegionCapture() }

    /// File ▸ Capture Full Page and the Site Control Center's full page button. [06 §24.2] observed.
    public func captureFullPage() { pageCapture.captureFullPage() }

    /// File ▸ Capture in Portrait Mode. [06 §24.3] observed.
    public func beginPortraitCapture() { pageCapture.beginPortraitCapture() }

    /// The capture items need a live web page in the selected tab (not an Easel).
    var canCapturePage: Bool { selectedLiveTab != nil && sidebar.selectedEaselID == nil }

    /// Runs the Site Control Center's capture buttons; the other two keep doing nothing.
    func installCaptureHandlers() {
        siteControls.toolHandler = { [weak self] tool, tabID in
            guard let self, self.selectedTabID == tabID else { return }
            switch tool {
            case .captureArea: self.beginRegionCapture()
            case .captureFullPage: self.captureFullPage()
            case .share, .newBoost: break
            }
        }
    }

    /// The selected page in window coordinates, for the region overlay: the single panel's page
    /// area, or the focused split pane's page (under its bar). Computed whether or not a capture
    /// runs: the window view does not observe the capture model, the layer does.
    func capturePageFrame(in layout: MainWindowLayout) -> CGRect? {
        guard let tabID = selectedTabID else { return nil }
        let panel = layout.webPanelFrame
        if activeSplitLayout != nil {
            let panes = splitPaneFrames(in: CGRect(origin: .zero, size: panel.size))
            guard let pane = panes.first(where: { $0.tabID == tabID }) else { return nil }
            let page = SplitPaneBarLayout(paneFrame: pane.frame).pageFrame
            return page.offsetBy(dx: panel.minX, dy: panel.minY)
        }
        return layout.pageFrame
    }
}
