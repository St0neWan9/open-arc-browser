import AppKit

// The region capture cursor (plan B139, F5-46): a crosshair with a small camera at its lower
// right. [06 §24.1] observed: the pointer becomes "crosshair + small camera" while selecting.
// The drawing is ours (CLAUDE.md: icons may differ); every size below is inferred, chosen to sit
// like the system crosshair (a 1 pt black cross with a white halo, so it reads on the 90 % dark
// dim and on the undimmed selection alike).

enum CaptureCursorTokens {
    /// The whole cursor image, in points. inferred.
    static let size = NSSize(width: 28, height: 28)
    /// The cross center = the hot spot, from the image's top left. inferred.
    static let hotSpot = NSPoint(x: 10, y: 10)
    /// Length of each arm from the center, and the gap left open around the center. inferred.
    static let armLength: CGFloat = 9
    static let centerGap: CGFloat = 2
    /// Line widths: the black cross and the white halo under it. inferred.
    static let lineWidth: CGFloat = 1
    static let haloWidth: CGFloat = 3
    /// The camera body (top-left origin, inside the image's lower right quadrant), its corner
    /// radius, the viewfinder bump on top and the lens. inferred.
    static let cameraBody = NSRect(x: 15, y: 17, width: 12, height: 9)
    static let cameraCornerRadius: CGFloat = 2
    static let cameraBump = NSRect(x: 18, y: 15, width: 5, height: 3)
    static let lensDiameter: CGFloat = 4.5
}

extension NSCursor {
    /// The region capture cursor: crosshair + small camera. [06 §24.1] observed; drawn by us.
    @MainActor static let captureRegion: NSCursor = NSCursor(image: captureRegionImage(), hotSpot: CaptureCursorTokens.hotSpot)

    /// The cursor's image, drawn at whatever scale the screen asks for (flipped: y down).
    static func captureRegionImage() -> NSImage {
        let t = CaptureCursorTokens.self
        let image = NSImage(size: t.size, flipped: true) { _ in
            let c = t.hotSpot
            let cross = NSBezierPath()
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                cross.move(to: NSPoint(x: c.x + dx * t.centerGap, y: c.y + dy * t.centerGap))
                cross.line(to: NSPoint(x: c.x + dx * t.armLength, y: c.y + dy * t.armLength))
            }
            cross.lineCapStyle = .square
            NSColor.white.setStroke()
            cross.lineWidth = t.haloWidth
            cross.stroke()
            NSColor.black.setStroke()
            cross.lineWidth = t.lineWidth
            cross.stroke()

            // Camera: a white body with a black outline, a bump on top and a black lens ring.
            let body = NSBezierPath(roundedRect: t.cameraBody, xRadius: t.cameraCornerRadius, yRadius: t.cameraCornerRadius)
            body.append(NSBezierPath(roundedRect: t.cameraBump, xRadius: 1, yRadius: 1))
            NSColor.white.setFill()
            body.fill()
            NSColor.black.setStroke()
            body.lineWidth = t.lineWidth
            body.stroke()
            let lensRect = NSRect(
                x: t.cameraBody.midX - t.lensDiameter / 2, y: t.cameraBody.midY - t.lensDiameter / 2 + 0.5,
                width: t.lensDiameter, height: t.lensDiameter
            )
            let lens = NSBezierPath(ovalIn: lensRect)
            lens.lineWidth = t.lineWidth
            lens.stroke()
            return true
        }
        image.accessibilityDescription = "Capture"
        return image
    }
}
