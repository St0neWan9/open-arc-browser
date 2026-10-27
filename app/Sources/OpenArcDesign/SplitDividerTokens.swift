import Foundation
import OpenArcModel

// The divider between split panes (plan B58).
// Spec: docs/arc-spec/06-flows.md §21.6 "调整比例" (E19 capture) and design-tokens.json
// `Metrics.SplitDivider`.

extension Metrics {
    public enum SplitDivider {
        /// The divider is the whole gap between two panes: the pointer shows the resize cursor
        /// exactly inside it. [06 §21.6] observed (10 pt).
        public static let hitThickness: Double = SplitView.paneGap
        /// A pane never gets narrower (or, in a vertical split, shorter) than this while the
        /// divider is dragged. [06 §21.6] observed for widths, both sides; heights inferred.
        public static let minPaneLength: Double = 220
        /// The only snap point: the two neighbors at equal size. [06 §21.6] observed (50 / 50, no
        /// snap at 1/3 or 2/3).
        public static let snapShare: Double = 0.5
        /// The divider center snaps to the equal-size position within this distance.
        /// [06 §21.6] observed (≈ 10 pt).
        public static let snapDistance: Double = 10
        /// Short grip centered in the gap, along the divider. [06 §21.6] observed (≈ 2 × 22 pt).
        public static let gripLength: Double = 22
        public static let gripThickness: Double = 2
        /// Grip color. [06 §21.6] observed ≈ #A7A2AA in the dark appearance; the light appearance
        /// was not captured (unknown, same value used).
        public static let gripColor = RGBAColor(hex: 0xA7A2AA)
    }
}
