import SwiftUI
import AppKit
import Combine
import QuartzCore
import OpenArcModel
import OpenArcDesign

// The icon that flies from the click to the Library button when a download starts (plan B203).
// [06 §43] observed (Arc 1.170, 2026-11-09, 57 fps recording of a 1920 × 985 window):
// - a white disc with a ring and a down arrow in the current Space's theme tone, with a soft glow;
// - it moves at a constant horizontal speed and falls like a thrown object: from the click it rises
//   ≈ 117 pt, then drops onto the badge, in ≈ 1.0 s (fitted: gravity ≈ 2640 pt/s²);
// - it fades in while growing from ≈ 30 to 44 pt in the first ≈ 0.17 s, then shrinks to ≈ 9 pt;
// - its arrow turns from ↘ to ↓ on the way.
// Starting at the pointer is inferred (the flight began next to the click in every run).

/// The flight's path, size and look over time. Pure, for tests.
enum DownloadFlightPath {
    static let duration: Double = 1.0
    /// Downward acceleration in points per second². Fitted to the recording.
    static let gravity: Double = 2640
    static let startDiameter: CGFloat = 30
    static let fullDiameter: CGFloat = 44
    static let endDiameter: CGFloat = 9
    static let growTime: Double = 0.17
    /// Ring and arrow width at the full size.
    static let lineWidth: CGFloat = 3.5
    /// The arrow's turn at the start (↘), radians on screen, clockwise positive.
    static let startArrowAngle: Double = -.pi / 4

    /// Position at `t` seconds, top-left based: x moves evenly, y falls under `gravity` and ends at
    /// `end` at `duration`.
    static func point(at t: Double, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let time = min(max(t, 0), duration)
        let x = start.x + (end.x - start.x) * CGFloat(time / duration)
        let launch = (Double(end.y - start.y) - 0.5 * gravity * duration * duration) / duration
        let y = Double(start.y) + launch * time + 0.5 * gravity * time * time
        return CGPoint(x: x, y: CGFloat(y))
    }

    static func diameter(at t: Double) -> CGFloat {
        if t <= growTime { return startDiameter + (fullDiameter - startDiameter) * CGFloat(max(t, 0) / growTime) }
        let share = CGFloat(min((t - growTime) / (duration - growTime), 1))
        return fullDiameter + (endDiameter - fullDiameter) * share
    }

    static func opacity(at t: Double) -> Double { min(max(t / growTime, 0), 1) }

    static func arrowAngle(at t: Double) -> Double { startArrowAngle * (1 - min(max(t / duration, 0), 1)) }
}

/// Runs the flights of one window over everything else. Transparent to the mouse.
struct DownloadFlightOverlay: NSViewRepresentable {
    let flights: PassthroughSubject<String, Never>
    /// The badge's center, top-left based in this view; nil while the sidebar is not shown.
    let target: CGPoint?
    /// The theme tone of the current Space.
    let tint: RGBAColor

    /// The badge's center in the window: the Library button's center (`SidebarLayout.dockHomeFrame`)
    /// plus the badge offset.
    static func badgeCenter(sidebarFrame: CGRect, windowHeight: CGFloat) -> CGPoint {
        let button = CGFloat(Metrics.Sidebar.dockHomeX + Metrics.Sidebar.dockButtonSize / 2)
        let offset = SidebarDownloadsShelfTokens.badgeOffset
        return CGPoint(x: sidebarFrame.minX + button + offset.width,
                       y: windowHeight - CGFloat(Metrics.Sidebar.dockCenterFromBottom) + offset.height)
    }

    func makeNSView(context: Context) -> DownloadFlightView {
        let view = DownloadFlightView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: DownloadFlightView, context: Context) {
        nsView.target = target
        nsView.tint = tint
        nsView.follow(flights)
    }
}

@MainActor
final class DownloadFlightView: NSView {
    var target: CGPoint?
    var tint = RGBAColor(hex: 0x000000)
    private var subscription: AnyCancellable?
    private weak var followed: PassthroughSubject<String, Never>?
    /// For tests: how many flights started.
    private(set) var flightCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func follow(_ flights: PassthroughSubject<String, Never>) {
        guard followed !== flights else { return }
        followed = flights
        subscription = flights.sink { [weak self] _ in
            // Sent on the main actor by `SidebarDownloadsShelf`.
            MainActor.assumeIsolated { self?.fly() }
        }
    }

    /// Starts a flight from the pointer (else the middle of the window) to `target`.
    func fly() {
        guard let target, let layer, bounds.width > 0 else { return }
        flightCount += 1
        // Layer space is bottom-left based; the path is computed top-left based and flipped.
        let height = bounds.height
        var start = CGPoint(x: bounds.midX, y: bounds.midY)
        if let window {
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(pointer) { start = CGPoint(x: pointer.x, y: height - pointer.y) }
        }
        let disc = Self.makeDisc(tint: tint.cgColor)
        layer.addSublayer(disc)

        let steps = 60
        let times = (0...steps).map { Double($0) / Double(steps) * DownloadFlightPath.duration }
        let keyTimes = times.map { NSNumber(value: $0 / DownloadFlightPath.duration) }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.calculationMode = .linear
            return animation
        }
        let position = keyframes("position", times.map { t -> NSValue in
            let p = DownloadFlightPath.point(at: t, from: start, to: target)
            return NSValue(point: CGPoint(x: p.x, y: height - p.y))
        })
        let scale = keyframes("transform.scale", times.map { DownloadFlightPath.diameter(at: $0) / DownloadFlightPath.fullDiameter })
        let opacity = keyframes("opacity", times.map { DownloadFlightPath.opacity(at: $0) })
        // Layer rotation is counterclockwise on screen; the path's angle is clockwise.
        let turn = keyframes("transform.rotation.z", times.map { -DownloadFlightPath.arrowAngle(at: $0) })

        let group = CAAnimationGroup()
        group.animations = [position, scale, opacity]
        group.duration = DownloadFlightPath.duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        turn.duration = DownloadFlightPath.duration
        turn.fillMode = .forwards
        turn.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { disc.removeFromSuperlayer() }
        disc.position = CGPoint(x: start.x, y: height - start.y)
        disc.opacity = 0
        disc.add(group, forKey: "flight")
        disc.sublayers?.last?.add(turn, forKey: "turn")
        CATransaction.commit()
    }

    /// The flying icon at its full size: a white disc, a tinted ring and arrow, a soft glow.
    static func makeDisc(tint: CGColor) -> CALayer {
        let size = DownloadFlightPath.fullDiameter
        let line = DownloadFlightPath.lineWidth
        let disc = CALayer()
        disc.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        disc.shadowColor = CGColor(red: 0.45, green: 0.5, blue: 1, alpha: 1)
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 10
        disc.shadowOffset = .zero

        let ring = CAShapeLayer()
        ring.frame = disc.bounds
        ring.path = CGPath(ellipseIn: disc.bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
        ring.fillColor = .white
        ring.strokeColor = tint
        ring.lineWidth = line
        disc.addSublayer(ring)

        // A down arrow in layer space (y up): shaft from the top to the tip, then the head.
        let arrow = CAShapeLayer()
        arrow.frame = disc.bounds
        let path = CGMutablePath()
        let mid = size / 2
        path.move(to: CGPoint(x: mid, y: size * 0.72))
        path.addLine(to: CGPoint(x: mid, y: size * 0.29))
        path.move(to: CGPoint(x: mid - size * 0.16, y: size * 0.45))
        path.addLine(to: CGPoint(x: mid, y: size * 0.29))
        path.addLine(to: CGPoint(x: mid + size * 0.16, y: size * 0.45))
        arrow.path = path
        arrow.fillColor = nil
        arrow.strokeColor = tint
        arrow.lineWidth = line
        arrow.lineCap = .round
        arrow.lineJoin = .round
        disc.addSublayer(arrow)
        return disc
    }
}

private extension RGBAColor {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
