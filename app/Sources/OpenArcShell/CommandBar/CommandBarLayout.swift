import CoreGraphics
import OpenArcDesign

// Pure geometry of the command bar (points, top-left origin, relative to the panel unless noted).
// Everything comes from `Metrics.CommandBar` ([07 §5] observed) / `Metrics.SplitView` /
// `Metrics.LittleArc`, except the constants marked below.

public struct CommandBarLayout: Equatable, Sendable {
    public var presentation: CommandBarPresentation
    public var resultCount: Int

    public init(presentation: CommandBarPresentation = .window, resultCount: Int) {
        self.presentation = presentation
        self.resultCount = max(0, resultCount)
    }

    /// Space below the last row: 327 − 64 − 4 − 5 × 50 = 9. [07 §5] inferred from the observed total.
    public static var bottomPadding: Double { Metrics.CommandBar.bottomPadding }

    /// Horizontal inset of a result row inside the panel. [07 §5] observed (7.5).
    public static var rowHorizontalInset: Double { Metrics.CommandBar.resultRowInset }

    /// Panel margin to the pane edges when the bar sits at the lower right of a pane.
    /// [06 §5] observed placement ("lower right of the right pane"); margin inferred as the pane gap.
    public static var paneMargin: Double { Metrics.SplitView.paneGap }

    public var panelWidth: Double {
        switch presentation {
        case .window: return Metrics.CommandBar.width
        case .pane: return Metrics.SplitView.paneCommandBarWidth
        case .littleArc: return Metrics.LittleArc.initialSize.width
        }
    }

    public var panelHeight: Double {
        let c = Metrics.CommandBar.self
        switch presentation {
        case .littleArc:
            return Metrics.LittleArc.initialSize.height
        case .window, .pane:
            guard resultCount > 0 else { return c.inputRowHeight }
            return c.inputRowHeight + c.resultsTopGap + Double(resultCount) * c.resultRowPitch + Self.bottomPadding
        }
    }

    public var panelSize: CGSize { CGSize(width: panelWidth, height: panelHeight) }

    public var inputRowFrame: CGRect {
        CGRect(x: 0, y: 0, width: panelWidth, height: Metrics.CommandBar.inputRowHeight)
    }

    /// Top of the first result row (panel + 68 = y 392 in the reference window). [07 §5] observed.
    public static var resultsTop: Double { Metrics.CommandBar.inputRowHeight + Metrics.CommandBar.resultsTopGap }

    /// Frame of result row `index` (the full 50 pt pitch), relative to the panel. [07 §5] observed.
    public func rowFrame(at index: Int) -> CGRect {
        let c = Metrics.CommandBar.self
        return CGRect(
            x: Self.rowHorizontalInset,
            y: Self.resultsTop + Double(index) * c.resultRowPitch,
            width: panelWidth - 2 * Self.rowHorizontalInset,
            height: c.resultRowPitch
        )
    }

    /// The selected fill inside row `index`: 2 pt in at the top and bottom (46 tall). [07 §5] observed.
    public func rowFillFrame(at index: Int) -> CGRect {
        let c = Metrics.CommandBar.self
        return rowFrame(at: index).insetBy(dx: 0, dy: (c.resultRowPitch - c.resultRowHeight) / 2)
    }

    /// Height of the scrolling result area (panel minus input row).
    public var resultsAreaHeight: Double { max(0, panelHeight - Metrics.CommandBar.inputRowHeight) }

    /// Panel frame inside its container (the window content, or the pane for `.pane`).
    /// - window: centered horizontally; the top is where a five-result panel sits (5 pt above the
    ///   center, y 324 in 985) and stays there while the results change. [07 §5] observed / inferred.
    /// - pane: lower right with `paneMargin`. [06 §5] observed.
    /// - littleArc: fills the container's top-left corner.
    public func panelFrame(in container: CGSize) -> CGRect {
        let width = min(panelWidth, container.width)
        let height = min(panelHeight, container.height)
        switch presentation {
        case .window:
            let x = (container.width - width) / 2
            let y = min(MainWindowLayout.commandBarTop(containerHeight: container.height), max(0, container.height - height))
            return CGRect(x: x, y: y, width: width, height: height)
        case .pane:
            return CGRect(
                x: max(0, container.width - width - Self.paneMargin),
                y: max(0, container.height - height - Self.paneMargin),
                width: width,
                height: height
            )
        case .littleArc:
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
    }
}
