import CoreGraphics
import OpenArcDesign

// Resizing the sidebar by dragging the seam between it and the web panel (B144). Pure, so the
// rules are unit-tested; `SidebarResizeHandle` feeds it the drag and `ShellModel` keeps the result.
// Values: `Metrics.Sidebar.defaultWidth` … `collapseWidth`, inferred (analysis).

/// What one step of a seam drag does to the sidebar.
enum SidebarResizeOutcome: Equatable, Sendable {
    /// The sidebar shows at this width.
    case width(Double)
    /// The drag went far enough left that the sidebar hides (the width it had stays).
    case hidden
}

/// The sidebar width rules: clamp, snap to the default, collapse past the left limit.
enum SidebarWidth {
    static var defaultWidth: Double { Metrics.Sidebar.defaultWidth }
    static var range: ClosedRange<Double> { Metrics.Sidebar.minimumWidth...Metrics.Sidebar.maximumWidth }

    /// A stored or restored width made valid: nil or out-of-range values become the nearest valid
    /// width (nil and non-finite values the default).
    static func sanitized(_ width: Double?) -> Double {
        guard let width, width.isFinite else { return defaultWidth }
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// The outcome of dragging the seam so the sidebar would be `proposed` wide (the width at the
    /// drag's start plus the horizontal translation). Rounded to whole points, collapsed below
    /// `collapseWidth`, clamped to `range`, and snapped to the default within its snap distance.
    /// inferred (analysis), B144.
    static func resize(proposed: Double) -> SidebarResizeOutcome {
        let s = Metrics.Sidebar.self
        let rounded = proposed.rounded()
        guard rounded >= s.collapseWidth else { return .hidden }
        let clamped = min(max(rounded, range.lowerBound), range.upperBound)
        if abs(clamped - defaultWidth) < s.defaultWidthSnapDistance { return .width(defaultWidth) }
        return .width(clamped)
    }
}
