import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Chrome of the floating bubbles: the shape (rounded rectangle plus an optional arrow), the
// translucent theme tint with a 1 pt light rim, and the borderless child panel that hosts it.
//
// Why a panel of our own instead of `.popover` (B42): an `NSPopover` always draws its own
// bubble (system material, its own small corner radius and arrow) behind the content. Our bubbles
// have larger radii (theme bubble 20, [07 §6]), so the popover's light chrome showed as square
// white corners behind them, and its arrow and anchor did not follow Arc ([07 §12]). The panel
// below is transparent (`isOpaque` false, clear background, no system shadow); everything visible
// is the shape we draw and clip.

/// The bubble outline: a continuous rounded rectangle, with the arrow on the edge that faces the
/// anchor. The rectangle passed to `path(in:)` includes the arrow's room. [07 §12] observed shape:
/// 45° flanks, a rounded tip, about 10.5 pt high and 26 pt wide at the base.
struct FloatingBubbleShape: Shape {
    var cornerRadius: CGFloat
    var arrow: FloatingBubbleArrow?

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect, cornerRadius: cornerRadius, arrow: arrow))
    }

    /// The bubble rectangle inside a frame that also holds the arrow.
    static func bubbleRect(in rect: CGRect, arrow: FloatingBubbleArrow?) -> CGRect {
        guard let arrow else { return rect }
        let height = CGFloat(Metrics.FloatingBubble.arrowHeight)
        switch arrow.edge {
        case .leading: return CGRect(x: rect.minX + height, y: rect.minY, width: rect.width - height, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
    }

    static func cgPath(in rect: CGRect, cornerRadius: CGFloat, arrow: FloatingBubbleArrow?) -> CGPath {
        let bubble = bubbleRect(in: rect, arrow: arrow)
        let body = Path(roundedRect: bubble, cornerRadius: cornerRadius, style: .continuous).cgPath
        guard let arrow else { return body }
        // Arrow pointing "up" from a base on y = 0, centered on x = 0; rotated for a leading edge.
        let half = CGFloat(Metrics.FloatingBubble.arrowBaseWidth) / 2
        let apex = half // 45° flanks: the sharp apex would be `half` above the base.
        let fillet: CGFloat = 2, tipRadius: CGFloat = 6
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: -half - fillet, y: 1))
        tri.addLine(to: CGPoint(x: -half - fillet, y: 0))
        tri.addArc(tangent1End: CGPoint(x: -half, y: 0), tangent2End: CGPoint(x: 0, y: -apex), radius: fillet)
        tri.addArc(tangent1End: CGPoint(x: 0, y: -apex), tangent2End: CGPoint(x: half, y: 0), radius: tipRadius)
        tri.addArc(tangent1End: CGPoint(x: half, y: 0), tangent2End: CGPoint(x: half + fillet, y: 0), radius: fillet)
        tri.addLine(to: CGPoint(x: half + fillet, y: 1))
        tri.closeSubpath()
        var transform: CGAffineTransform
        switch arrow.edge {
        case .top:
            transform = CGAffineTransform(translationX: bubble.minX + arrow.position, y: bubble.minY)
        case .leading:
            // Rotate -90°: "up" becomes "left".
            transform = CGAffineTransform(translationX: bubble.minX, y: bubble.minY + arrow.position).rotated(by: -.pi / 2)
        }
        guard let placed = tri.copy(using: &transform) else { return body }
        return body.union(placed)
    }
}

/// The visible bubble: theme tint over the panel's blur, 1 pt light inner rim, content clipped to
/// the shape. `size` is the bubble rectangle (without the arrow).
struct FloatingBubbleChrome<Content: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    let arrow: FloatingBubbleArrow?
    /// Theme tint (`ThemePalette.floatingPanelBackground`).
    let tint: RGBAColor
    let isDark: Bool
    /// Translucent over a blur (live bubble) or opaque (snapshot tests, no blur behind).
    var tintOpacity: Double = Metrics.FloatingBubble.tintOpacity
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = FloatingBubbleShape(cornerRadius: cornerRadius, arrow: arrow)
        let outer = FloatingBubbleChrome.outerSize(size: size, arrow: arrow)
        let bubble = FloatingBubbleShape.bubbleRect(in: CGRect(origin: .zero, size: outer), arrow: arrow)
        let b = Metrics.FloatingBubble.self
        ZStack(alignment: .topLeading) {
            shape.fill(tint.swiftUI.opacity(tintOpacity))
            content()
                .frame(width: size.width, height: size.height)
                .offset(x: bubble.minX, y: bubble.minY)
            shape.stroke(Color.white.opacity(isDark ? b.rimOpacityDark : b.rimOpacityLight), lineWidth: CGFloat(b.rimWidth) * 2)
                .allowsHitTesting(false)
        }
        .frame(width: outer.width, height: outer.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    static func outerSize(size: CGSize, arrow: FloatingBubbleArrow?) -> CGSize {
        guard let arrow else { return size }
        let height = CGFloat(Metrics.FloatingBubble.arrowHeight)
        switch arrow.edge {
        case .leading: return CGSize(width: size.width + height, height: size.height)
        case .top: return CGSize(width: size.width, height: size.height + height)
        }
    }
}

/// Borderless, transparent child panel for bubbles and the hover card. Not key unless `allowsKey`:
/// the keyboard stays with the browser window (Escape is caught by `FloatingBubbleController`).
final class FloatingBubblePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // Arc's bubbles have no drop shadow [07 §12] observed; the hover card draws its own.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    /// Only a bubble that hosts a page (an extension popup, C14) takes the keyboard.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click, so a press on a non-key bubble acts at once.
final class FloatingBubbleHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
