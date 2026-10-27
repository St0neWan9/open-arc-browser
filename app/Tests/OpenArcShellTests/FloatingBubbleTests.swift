import XCTest
import SwiftUI
import AppKit
import OpenArcModel
@testable import OpenArcDesign
@testable import OpenArcShell

/// B42: placement of every floating bubble and the Little Arc window ([07 §12] observed in the
/// reference app, window 1281 × 801 at screen (199, 152)), and the bubble chrome: transparent
/// panel, nothing drawn outside the rounded shape.
@MainActor
final class FloatingBubbleTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1281, height: 801)

    // MARK: Placement

    /// [07 §12] observed: "Choose a Theme" (row x 14–262, y 323–359 in the window) puts the 356 ×
    /// 508 bubble at x 275 (13 right of the row), vertically centered on the row, arrow on its
    /// leading edge pointing at the row's center.
    func testChooseThemeBubbleRightOfRow() {
        let row = CGRect(x: 14, y: 323, width: 248, height: 36)
        let f = FloatingBubbleLayout.attached(anchor: row, side: .trailing, size: CGSize(width: 356, height: 508),
                                              container: window, cornerRadius: 20)
        XCTAssertEqual(f.bubble.minX, 275)
        XCTAssertEqual(f.bubble.midY, row.midY, accuracy: 0.5)
        XCTAssertEqual(f.bubble.minY, 87)
        XCTAssertEqual(f.arrow?.edge, .leading)
        XCTAssertEqual(f.arrow?.position ?? 0, row.midY - f.bubble.minY, accuracy: 0.01)
        // The arrow fills the 13 pt gap minus a 2.5 pt clearance; its window starts left of the bubble.
        XCTAssertEqual(f.outerFrame.minX, 275 - Metrics.FloatingBubble.arrowHeight)
    }

    /// [07 §12] observed: the Site Control Center (236 wide) opens 12 below the 30 × 30 icon at
    /// x 234–264, y 49–79, centered on it, arrow on top pointing at the icon.
    func testSiteControlsBelowIcon() {
        let icon = CGRect(x: 234, y: 49, width: 30, height: 30)
        let f = FloatingBubbleLayout.attached(anchor: icon, side: .below, size: CGSize(width: 236, height: 297),
                                              container: window, cornerRadius: 20)
        XCTAssertEqual(f.bubble.minY, 91)
        XCTAssertEqual(f.bubble.midX, icon.midX, accuracy: 0.01)
        XCTAssertEqual(f.arrow, FloatingBubbleArrow(edge: .top, position: 118))
    }

    /// Near the window edge the bubble is clamped 13 pt inside and its arrow keeps pointing at the
    /// anchor, outside the rounded corners. inferred.
    func testAttachedBubbleClampsAndArrowFollowsAnchor() {
        let icon = CGRect(x: 2, y: 49, width: 30, height: 30)
        let f = FloatingBubbleLayout.attached(anchor: icon, side: .below, size: CGSize(width: 236, height: 297),
                                              container: window, cornerRadius: 20)
        XCTAssertEqual(f.bubble.minX, Metrics.FloatingBubble.windowMargin)
        let limit = 20 + Metrics.FloatingBubble.arrowBaseWidth / 2
        XCTAssertEqual(f.arrow?.position ?? 0, CGFloat(limit))
    }

    /// [07 §12] observed: Edit Theme… has no arrow; x = web panel + 13 (289), the bubble is
    /// centered on the pointer's height and clamped 13 pt inside the window: pointer at window
    /// y 448 → top 194; y 148 → 13; y 648 → 280 (801 − 13 − 508).
    func testEditThemeBubbleAtPointerHeight() {
        let size = CGSize(width: 356, height: 508)
        for (pointer, top) in [(CGFloat(448), CGFloat(194)), (148, 13), (648, 280)] {
            let f = FloatingBubbleLayout.editTheme(pointerY: pointer, webPanelMinX: 276, size: size, container: window)
            XCTAssertNil(f.arrow)
            XCTAssertEqual(f.bubble.minX, 289)
            XCTAssertEqual(f.bubble.minY, top, "pointer y \(pointer)")
        }
    }

    /// [07 §12] observed: the hover card's top left is the pointer + (11.5, 5.5); it is kept on
    /// screen (inferred).
    func testHoverCardFollowsPointerAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1920, height: 985)
        let size = CGSize(width: 141.5, height: 42.5)
        XCTAssertEqual(FloatingBubbleLayout.hoverCard(pointer: CGPoint(x: 250, y: 472), size: size, screen: screen).origin,
                       CGPoint(x: 261.5, y: 477.5))
        let edge = FloatingBubbleLayout.hoverCard(pointer: CGPoint(x: 1900, y: 1000), size: size, screen: screen)
        XCTAssertEqual(edge.maxX, screen.maxX)
        XCTAssertEqual(edge.maxY, screen.maxY)
    }

    /// [07 §12] observed: Little Arc (490 × 329) opens at the top right of the visible screen
    /// area, 20 pt from its right and top edges: (1410, 50) on a 1920-wide screen whose visible
    /// area starts at y 30.
    func testLittleArcTopRight() {
        let visible = CGRect(x: 0, y: 30, width: 1920, height: 985)
        let origin = FloatingBubbleLayout.littleArcOrigin(size: CGSize(width: 490, height: 329), visible: visible)
        XCTAssertEqual(origin, CGPoint(x: 1410, y: 50))
    }

    // MARK: Chrome

    /// B42: the bubble panel is transparent and casts no system shadow, so only the drawn shape shows.
    func testPanelIsTransparent() {
        let panel = FloatingBubblePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.canBecomeKey)
    }

    /// B42: rendered on a transparent surface, the bubble's corners stay fully transparent (no
    /// square background behind the radius 20 corners), its middle is opaque tint, and the area
    /// beside the arrow is transparent. Light and dark. [07 §12] observed (fully rounded).
    func testBubbleCornersAreTransparent() throws {
        for isDark in [false, true] {
            let size = CGSize(width: 200, height: 160)
            let arrow = FloatingBubbleArrow(edge: .top, position: 100)
            let chrome = FloatingBubbleChrome(size: size, cornerRadius: 20, arrow: arrow, tint: RGBAColor(hex: isDark ? 0x5C4457 : 0xFDF1FA),
                                              isDark: isDark, tintOpacity: 1) { Color.white }
            let outer = FloatingBubbleChrome<Color>.outerSize(size: size, arrow: arrow)
            let rep = try render(chrome, size: outer)
            let h = CGFloat(Metrics.FloatingBubble.arrowHeight)
            // Bubble corners (1.5 pt inside each corner of the bubble rectangle).
            for p in [CGPoint(x: 1.5, y: h + 1.5), CGPoint(x: outer.width - 1.5, y: h + 1.5),
                      CGPoint(x: 1.5, y: outer.height - 1.5), CGPoint(x: outer.width - 1.5, y: outer.height - 1.5)] {
                XCTAssertLessThan(alpha(rep, p), 0.05, "corner \(p) dark \(isDark)")
            }
            // Beside the arrow, above the bubble.
            XCTAssertLessThan(alpha(rep, CGPoint(x: 30, y: 2)), 0.05)
            // The arrow tip region and the middle are drawn.
            XCTAssertGreaterThan(alpha(rep, CGPoint(x: 100, y: h - 2)), 0.9)
            XCTAssertGreaterThan(alpha(rep, CGPoint(x: 100, y: outer.height / 2)), 0.99)
        }
    }

    // MARK: Motion (B92, [07 §11])

    /// The bubble grows from its anchor: the arrow tip when attached, the bottom-left corner from
    /// a menu. [07 §11] observed (bottom-left anchor for Edit Theme…); arrow tip inferred.
    func testGrowthOrigin() {
        let size = CGSize(width: 366.5, height: 508)
        XCTAssertEqual(FloatingBubbleMotion.growthOrigin(arrow: nil, size: size), .zero)
        XCTAssertEqual(FloatingBubbleMotion.growthOrigin(arrow: FloatingBubbleArrow(edge: .leading, position: 100), size: size),
                       CGPoint(x: 0, y: 408), "leading arrow tip (bottom-left origin)")
        XCTAssertEqual(FloatingBubbleMotion.growthOrigin(arrow: FloatingBubbleArrow(edge: .top, position: 50), size: size),
                       CGPoint(x: 50, y: 508), "top arrow tip")
        // The collapsed transform keeps the origin in place.
        let bounds = CGRect(origin: .zero, size: size)
        let t = FloatingBubbleMotion.transform(scale: 0.01, about: CGPoint(x: 0, y: 408), bounds: bounds, anchorPoint: CGPoint(x: 0.5, y: 0.5))
        let pivot = CGPoint(x: bounds.midX, y: bounds.midY)
        let p = CGPoint(x: 0 - pivot.x, y: 408 - pivot.y)
        let mapped = CGPoint(x: p.x * t.m11 + p.y * t.m21 + t.m41 + pivot.x, y: p.x * t.m12 + p.y * t.m22 + t.m42 + pivot.y)
        XCTAssertEqual(mapped.x, 0, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, 408, accuracy: 1e-9)
    }

    /// The springs carry the tokens' constants: open 0.31 s / 0.81, close 0.35 s / 0.85, scale
    /// and alpha on the same curve. [07 §11] observed.
    func testSpringsUseMotionTokens() throws {
        for (phase, token) in [(FloatingBubbleMotion.Phase.open, Motion.themeBubbleOpen), (.close, Motion.themeBubbleClose)] {
            let constants = try XCTUnwrap(token.curve.springConstants)
            for key in ["transform", "opacity"] {
                let spring = FloatingBubbleMotion.spring(key, from: 0, to: 1, phase: phase)
                XCTAssertEqual(spring.stiffness, constants.stiffness, accuracy: 1e-9)
                XCTAssertEqual(spring.damping, constants.damping, accuracy: 1e-9)
                XCTAssertEqual(spring.mass, 1)
                XCTAssertEqual(spring.duration, spring.settlingDuration)
            }
        }
        XCTAssertEqual(FloatingBubbleMotion.token(.open), Motion.themeBubbleOpen)
        XCTAssertEqual(FloatingBubbleMotion.token(.close), Motion.themeBubbleClose)
    }

    /// The panel controller runs the open spring when a bubble appears and keeps the panel on
    /// screen while the close spring runs, ordering it out once it settles. [07 §11] observed:
    /// open grows with alpha; close shrinks and fades (≈ 270 ms to alpha 0).
    func testControllerAnimatesOpenAndClose() async throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = FloatingBubbleAnchor.AnchorView(frame: NSRect(x: 20, y: 300, width: 200, height: 36))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }

        let controller = FloatingBubbleController()
        controller.anchorView = anchor
        controller.request = FloatingBubbleRequest(
            placement: .attached(.trailing),
            style: FloatingBubbleStyle(width: 200, height: 160, cornerRadius: 20, tint: RGBAColor(hex: 0xFDF1FA), isDark: false, usesGradient: true),
            content: AnyView(Color.clear), onDismiss: { _ in })
        controller.schedule()
        try await Task.sleep(nanoseconds: 50_000_000)
        let panel = try XCTUnwrap(controller.panel)
        let layer = try XCTUnwrap(panel.contentView?.layer)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(layer.animation(forKey: FloatingBubbleMotion.scaleKey), "grows from the anchor")
        XCTAssertNotNil(layer.animation(forKey: FloatingBubbleMotion.opacityKey), "fades in on the same spring")

        controller.request = nil
        controller.hide()
        XCTAssertTrue(controller.isClosing)
        XCTAssertTrue(panel.isVisible, "still shrinking")
        XCTAssertTrue(panel.ignoresMouseEvents, "a closing bubble lets clicks through")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(panel.isVisible, "ordered out after the close spring")
        XCTAssertFalse(controller.isClosing)
        XCTAssertNil(layer.animation(forKey: FloatingBubbleMotion.scaleKey), "reset for the next open")
    }

    /// B42: the modal card is clipped to its radius 26 corners. [07 §12] observed. (Since B91 the
    /// card is drawn in the window, not in a system sheet window.)
    func testModalCardCornersAreTransparent() throws {
        let palette = ThemeDerivation.palette(for: nil)
        let card = ModalCard(size: Metrics.Dialog.newFolderSize, palette: palette) { Text("New Folder…") } buttons: { AnyView(EmptyView()) }
        let size = CGSize(width: Metrics.Dialog.newFolderSize.width, height: Metrics.Dialog.newFolderSize.height)
        let rep = try render(card, size: size)
        XCTAssertLessThan(alpha(rep, CGPoint(x: 1.5, y: 1.5)), 0.05)
        XCTAssertLessThan(alpha(rep, CGPoint(x: size.width - 1.5, y: size.height - 1.5)), 0.05)
        XCTAssertGreaterThan(alpha(rep, CGPoint(x: size.width / 2, y: size.height / 2)), 0.99)
    }

    // MARK: Helpers

    private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    /// Alpha at a point (top-left based, in points) of a 2× rendering.
    private func alpha(_ rep: NSBitmapImageRep, _ p: CGPoint) -> CGFloat {
        let x = min(rep.pixelsWide - 1, Int(p.x * 2)), y = min(rep.pixelsHigh - 1, Int(p.y * 2))
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}
