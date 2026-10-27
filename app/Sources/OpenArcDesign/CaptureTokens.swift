import Foundation
import OpenArcModel

// Capture tool tokens (plan B51). Source: docs/arc-spec/06-flows.md §24 (E4) and
// design-tokens.json `Metrics.Capture`. Labels per value.

extension Metrics {
    public enum Capture {
        /// Region capture: the web panel is dimmed to near black. [06 §24.1] observed (≈ 90 %).
        public static let dimOpacity: Double = 0.9
        /// Selection border width. [06 §24.1] observed (≈ 1 pt, dark blue tone).
        public static let selectionBorderWidth: Double = 1
        /// Selection border color. inferred (a dark blue).
        public static let selectionBorderColor = RGBAColor(hex: 0x1E3A8A)
        /// Smallest selection that counts as a drag; smaller releases keep selecting. inferred.
        public static let minimumSelectionSide: Double = 4

        /// "Drag to capture a portion of this page" card: ≈ 370 × 70, radius ≈ 12, centered,
        /// bottom edge 37 above the panel bottom. design-tokens `regionHintCard` (inferred, PX
        /// estimate of the observed card).
        public static let hintCardSize = Size2D(width: 370, height: 70)
        public static let hintCardCornerRadius: Double = 12
        public static let hintCardBottomInset: Double = 37
        /// Purple bold text of the card. [06 §24.1] observed "purple bold"; tone inferred.
        public static let hintTextColor = RGBAColor(hex: 0x5B2BD6)
        public static let hintTextSize: Double = 15
        /// The colorful glow behind the card (orange → blue). [06 §24.1] observed; radius inferred.
        public static let hintGlowColors = [RGBAColor(hex: 0xFF8A3D), RGBAColor(hex: 0x3D7BFF)]
        public static let hintGlowRadius: Double = 18

        /// Label at the selection's top-left, outside it: its bottom touches the selection's top
        /// edge, its left edge ≈ 25 pt left of the selection. [06 §24.1] observed.
        public static let selectionLabelLeadingOutset: Double = 25
        public static let selectionLabelHeight: Double = 22

        /// Result menu: 273 × 354, 13 pt right of the selection, top edges aligned.
        /// design-tokens `resultMenu` observed (AX).
        public static let resultMenuSize = Size2D(width: 273, height: 354)
        public static let resultMenuGap: Double = 13
        /// Dark menu panel fill and corner radius. inferred ("dark menu panel" observed).
        public static let resultMenuFill = RGBAColor(hex: 0x232129)
        public static let resultMenuCornerRadius: Double = 12
        /// Menu row height and the "Send To…" field height. inferred (354 pt for 7 rows, the field
        /// and 2 separators).
        public static let resultMenuRowHeight: Double = 36
        public static let resultMenuFieldHeight: Double = 40
        /// The menu keeps this far inside the web panel. inferred.
        public static let resultMenuPanelMargin: Double = 8

        /// "Screenshot Copied to Clipboard · Save · share" bar: 317 × 46 at the panel's top right,
        /// 4 from the top, 8 from the right, fill ≈ #27134C, white text. design-tokens `doneToast`
        /// observed (PX).
        public static let doneToastSize = Size2D(width: 317, height: 46)
        public static let toastTopInset: Double = 4
        public static let toastTrailingInset: Double = 8
        public static let toastFill = RGBAColor(hex: 0x27134C)
        /// "Copied Image" and the first-run shortcut hint use the same dark purple pill. [06 §24.1]
        /// observed "dark purple capsule"; height inferred.
        public static let pillHeight: Double = 32
        /// How long a toast stays. unknown ([06 §24.5]: display time not measured).
        public static let toastDuration: Double = 4

        /// Portrait mode bubble: window 286 × 246, content 260 × 220, inset 13, primary button
        /// 240 × 32, no arrow, centered on the web panel. design-tokens `portraitBubble` observed (AX).
        public static let portraitBubbleSize = Size2D(width: 286, height: 246)
        public static let portraitBubbleInset: Double = 13
        public static let portraitPrimaryButtonSize = Size2D(width: 240, height: 32)
        /// The portrait page thumbnail in the preview: ≈ 83 × 96. [06 §24.3] observed.
        public static let portraitThumbnailSize = Size2D(width: 83, height: 96)
        /// Watermark toggle at the preview's lower left: 32 × 32. [06 §24.3] observed.
        public static let portraitWatermarkButtonSize: Double = 32
        /// Height / width of the page part a portrait image keeps: the thumbnail's proportion.
        /// inferred (96 / 83 from the observed thumbnail).
        public static let portraitPageAspect: Double = 96.0 / 83.0
        /// Background margin around the page in the portrait image, as a share of the page width.
        /// inferred.
        public static let portraitMarginRatio: Double = 0.08
        /// Default background hue (the observed "blue gradient"). inferred value.
        public static let portraitDefaultHue: Double = 0.6
    }
}
