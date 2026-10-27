import Foundation

// The favorites grid at the top of the sidebar (plan B55).
// Spec: docs/arc-spec/06-flows.md §21.2–§21.3 (E19 capture), docs/arc-spec/04-visual-metrics.md
// "收藏网格" table and design-tokens.json `Metrics.FavoritesGrid`.

extension Metrics {
    public enum FavoritesGrid {
        /// Tile height. [06 §21.3] observed (47).
        public static let tileHeight: Double = 47
        /// Inset of the tiles inside the favorites area: 8 left / right (tiles x 8–268, 260 wide)
        /// and 8 above / below. [06 §21.3] observed.
        public static let inset: Double = 8
        /// Gap between tiles, both directions (row pitch 55). [06 §21.3] observed.
        public static let spacing: Double = 8
        /// At most four columns. [06 §21.3] inferred from n = 1, 2, 4–9 (rule rows = ⌈n / 4⌉,
        /// columns = ⌈n / rows⌉).
        public static let maxColumns: Int = 4
        /// Height of the favorites area with one row of tiles (8 + 47 + 8). [06 §21.3] observed (63).
        public static var oneRowAreaHeight: Double { inset + tileHeight + inset }

        /// The empty-state card: x 8–268, ≈ 89 tall; the area around it is 105 tall.
        /// [06 §21.2] observed (AX list area height 105, card ≈ 89).
        public static let emptyStateCardHeight: Double = 89
        /// The card's dismiss button ("Dismiss" ✕): 14 × 14, 8 from the card's right edge.
        /// [06 §21.2] observed (x 246 in a card at x 8–268). Its distance from the top: inferred (8).
        public static let emptyStateDismissSize: Double = 14
        public static let emptyStateDismissInset: Double = 8
        /// The filled star badge centered in the card. [06 §21.2] observed (16 × 16).
        public static let emptyStateStarSize: Double = 16
        /// Card corner radius and dash pattern. inferred (the capture only says "dashed, rounded").
        public static let emptyStateCornerRadius: Double = 12
        public static let emptyStateDash: [Double] = [4, 3]
        public static let emptyStateBorderWidth: Double = 1
        /// Card ink opacities: dashed border, star badge. inferred (the capture shows a light tint).
        public static let emptyStateBorderOpacity: Double = 0.25
        public static let emptyStateStarOpacity: Double = 0.8
        /// Vertical gap between the star, the title and the detail lines. inferred.
        public static let emptyStateLineSpacing: Double = 4
        /// Side padding of the two-line detail text inside the card. inferred.
        public static let emptyStateDetailPadding: Double = 24

        /// Selected tile fill in the dark appearance: the window color with ≈ 47 % white
        /// (#2C283E → #8F9099, default dark purple theme). [06 §21.3] observed color, the white
        /// amount is derived from it. The light appearance was not captured.
        public static let selectedTileWhiteDark: Double = 0.47
    }
}
