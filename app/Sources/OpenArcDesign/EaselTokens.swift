import Foundation
import OpenArcModel

// Easel canvas tokens (plan B56). Spec: docs/arc-spec/06-flows.md §9 (observed: the full-page
// canvas, a centered bold title of about 24 pt, scroll bars on both axes, a floating toolbar at the
// lower left, an "add collaborator" button at the lower right). Every size, color, stroke width and
// handle below was not measured: they are inferred (chosen to look like the observed surface) or
// unknown placeholders. Replace them when a capture measures them.

extension Metrics {
    public enum Easel {
        /// Canvas size. The page scrolls both ways ([06 §9] observed: scroll bars on the right and
        /// at the bottom), so the canvas is larger than the panel. inferred.
        public static let canvasSize = Size2D(width: 3000, height: 2000)
        /// Least room kept around the elements: the canvas grows to keep this much past the farthest
        /// element. inferred.
        public static let canvasGrowthMargin: Double = 400

        /// Title: centered at the top. [06 §9] observed (position, ≈ 24 pt bold); the top inset is
        /// inferred.
        public static let titleTopInset: Double = 40
        public static let titleFontSize: Double = 24
        /// Width of the title field. inferred.
        public static let titleMaxWidth: Double = 520

        /// Floating toolbar at the lower left. [06 §9] observed (position); sizes inferred.
        public static let toolbarInset: Double = 16
        public static let toolbarButtonSize: Double = 32
        public static let toolbarButtonSpacing: Double = 2
        public static let toolbarPadding: Double = 4
        public static let toolbarCornerRadius: Double = 12
        public static let toolbarIconSize: Double = 15
        /// Collaborator button at the lower right. [06 §9] observed (position); size inferred.
        public static let collaboratorButtonSize: Double = 36

        /// Selection outline and resize handles. unknown (not observed); our own.
        public static let selectionOutlineWidth: Double = 1.5
        public static let handleSize: Double = 8
        /// How far outside a thin shape (arrow, pen) a click still hits it. inferred.
        public static let hitSlop: Double = 6

        /// A shape drawn with a click and no drag gets this size. inferred.
        public static let defaultShapeSize = Size2D(width: 160, height: 120)
        /// A new text box. inferred.
        public static let defaultTextSize = Size2D(width: 220, height: 40)
        /// Largest side of a newly placed image (points); larger images are scaled down. inferred.
        public static let maxPlacedImageSide: Double = 480
        /// Largest side (pixels) an image is downsized to before it is stored inline
        /// (`EaselImage.maxEncodedBytes`). inferred.
        public static let maxStoredImagePixels: Double = 1600
        /// Least frame side; smaller drags are clamped. inferred.
        public static let minimumElementSide: Double = 8
        /// Pen points closer than this (points) to the last one are dropped. inferred.
        public static let penMinimumPointDistance: Double = 1.5
    }
}

/// Default styles of new Easel elements. All inferred: [06 §9] shows the tools, not their output.
public enum EaselTokens {
    /// Ink of outlines, arrows, pen strokes and text: near-black. inferred.
    public static let ink = RGBAColor(hex: 0x1F1F1F)
    /// Fill of new circles and rectangles: none (outline only). inferred.
    public static let shapeFill: RGBAColor? = nil
    public static let shapeStrokeWidth: Double = 3
    public static let arrowStrokeWidth: Double = 3
    public static let penStrokeWidth: Double = 3
    public static let textFontSize: Double = 18
    /// Arrow head: length and half-angle (degrees). inferred.
    public static let arrowHeadLength: Double = 14
    public static let arrowHeadHalfAngle: Double = 28
    /// Selection outline and handles: a system-like accent blue. unknown.
    public static let selectionColor = RGBAColor(hex: 0x3D7BFD)
    /// Canvas background (light / dark). inferred: the canvas is a page, like about:blank in
    /// [07 §8.1] (#FFFFFF light, #121212 dark, observed for about:blank).
    public static let canvasBackgroundLight = RGBAColor(hex: 0xFFFFFF)
    public static let canvasBackgroundDark = RGBAColor(hex: 0x121212)
    /// Ink in dark mode. inferred.
    public static let inkDark = RGBAColor(hex: 0xEDEDED)
    /// Toolbar: a white floating card with a soft shadow; the selected tool on a gray block.
    /// inferred.
    public static let toolbarBackground = RGBAColor(hex: 0xFFFFFF)
    public static let toolbarSelectedFill = RGBAColor(hex: 0x000000, alpha: 0.08)
    public static let toolbarIcon = RGBAColor(hex: 0x000000, alpha: 0.75)
    public static let toolbarShadowOpacity: Double = 0.14

    /// The default style of a new element of `kind`.
    public static func defaultStyle(for kind: EaselElementKind) -> EaselStyle {
        switch kind {
        case .circle, .rectangle:
            return EaselStyle(strokeColor: ink, fillColor: shapeFill, strokeWidth: shapeStrokeWidth, fontSize: textFontSize)
        case .arrow:
            return EaselStyle(strokeColor: ink, strokeWidth: arrowStrokeWidth, fontSize: textFontSize)
        case .pen:
            return EaselStyle(strokeColor: ink, strokeWidth: penStrokeWidth, fontSize: textFontSize)
        case .text, .image:
            return EaselStyle(strokeColor: ink, strokeWidth: shapeStrokeWidth, fontSize: textFontSize)
        }
    }
}

extension Typography {
    /// Easel title: ≈ 24 pt bold. [06 §9] observed (size estimated from the capture).
    public static let easelTitle = TextStyle(size: 24, weight: .bold)
}
