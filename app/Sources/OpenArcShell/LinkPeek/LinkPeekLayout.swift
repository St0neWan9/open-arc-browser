import CoreGraphics
import OpenArcDesign

// Frames of the Peek surface (plan B49), window coordinates with a top-left origin, so the
// geometry is testable without rendering. Spec: [06 §22.2] observed in a 1920 × 985 window;
// the scaling rule for other sizes is inferred ([06 §22.5] lists it as not captured).

struct LinkPeekLayout: Equatable {
    /// The window's size.
    var windowSize: CGSize
    /// The web panel's frame without Peek (`MainWindowLayout.webPanelFrame` with no Peek inset).
    var webPanelFrame: CGRect

    /// The floating panel. At the reference size: x 440–1755, y 12–972. [06 §22.2] observed.
    /// Its width follows the web panel (1315 / 1634) and its center sits 4.5 pt right of the web
    /// panel's center; it spans the window's height minus 12 above and 13 below. Kept far enough
    /// from the right edge for the button column (inferred).
    var panelFrame: CGRect {
        let p = PeekMetrics.self
        let width = max(0, webPanelFrame.width * p.widthFraction)
        var x = webPanelFrame.midX + p.centerOffsetX - width / 2
        let buttonsRight = x + width + p.buttonGap + p.buttonSize.width
        let limit = windowSize.width - p.minimumTrailingMargin
        if buttonsRight > limit { x -= buttonsRight - limit }
        x = max(webPanelFrame.minX, x)
        let height = max(0, windowSize.height - p.windowInsetTop - p.windowInsetBottom)
        return CGRect(x: x, y: p.windowInsetTop, width: width, height: height)
    }

    /// The page behind: the web panel shrunk by ≈ 9.5 pt on every side. [06 §22.2] observed.
    var backgroundFrame: CGRect {
        webPanelFrame.insetBy(dx: PeekMetrics.backgroundInset, dy: PeekMetrics.backgroundInset)
    }

    /// The round buttons, top to bottom: close, expand to a tab, open in split. 34 × 33, 13 pt
    /// right of the panel, the first at the panel's top + 7, pitch 44. [06 §22.2] observed.
    var buttonFrames: [CGRect] {
        let p = PeekMetrics.self
        let panel = panelFrame
        return (0..<LinkPeekButtonKind.allCases.count).map { index in
            CGRect(
                x: panel.maxX + p.buttonGap,
                y: panel.minY + p.firstButtonOffsetY + Double(index) * p.buttonPitch,
                width: p.buttonSize.width,
                height: p.buttonSize.height
            )
        }
    }
}

/// The buttons right of the panel, in their order. [06 §22.2] observed.
enum LinkPeekButtonKind: CaseIterable, Equatable {
    case close, expand, split
}

extension MainWindowLayout {
    /// This layout with the page behind Peek shrunk. [06 §22.2] observed (B49).
    func withPeekInset() -> MainWindowLayout {
        var layout = self
        layout.peekBackgroundInset = PeekMetrics.backgroundInset
        return layout
    }
}
