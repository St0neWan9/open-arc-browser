import Foundation
import Combine
import CoreGraphics
import OpenArcDesign

// Drives `SidebarPeekMachine` from pointer events and a timer. One per window, owned by
// `ShellModel` and kept in step with `isSidebarVisible`. [06 §14] observed behavior.

@MainActor
final class SidebarPeekController: ObservableObject {
    /// pinned / hidden / peeking. Published only when it changes (pointer moves do not publish).
    @Published private(set) var presentation: SidebarPresentation
    private var machine: SidebarPeekMachine

    /// The clock. Tests pass a fake one.
    var now: () -> Date
    /// Runs `work` after `delay` seconds on the main actor. Tests install a recorder.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        isPinned: Bool = true,
        timing: SidebarPeekTiming = .standard,
        now: @escaping () -> Date = Date.init,
        schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        let machine = SidebarPeekMachine(isPinned: isPinned, timing: timing)
        self.machine = machine
        self.presentation = machine.presentation
        self.now = now
        self.schedule = schedule ?? { delay, work in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                work()
            }
        }
    }

    /// Follows the window's sidebar visibility: shown = pinned, hidden = hidden (closing a peek).
    func setPinned(_ pinned: Bool) {
        if pinned {
            guard machine.presentation != .pinned else { return }
            machine.pin()
        } else {
            guard machine.presentation == .pinned else { return }
            machine.hide()
        }
        publish()
    }

    /// The previous pointer position was in the left-edge zone: the strip outside the window is
    /// then the wide one (`SidebarPeekLayout.edgeZone(isInside:)`). B145.
    private var wasAtEdge = false
    /// The window's sidebar width (B144): the floating panel, and so the zone that keeps it open,
    /// is that wide.
    var sidebarWidth: CGFloat = CGFloat(Metrics.Sidebar.width)

    /// The pointer is at `point` (window coordinates, top-left origin; negative x left of the
    /// window) in a window of `windowSize`; nil when its position is unknown.
    func pointerMoved(to point: CGPoint?, windowSize: CGSize) {
        let region = point.map {
            SidebarPeekLayout(windowSize: windowSize, sidebarWidth: sidebarWidth)
                .region(of: $0, presentation: machine.presentation, wasAtEdge: wasAtEdge)
        } ?? .outside
        wasAtEdge = region == .edge
        pointer(region)
    }

    /// The pointer is in `region`.
    func pointer(_ region: SidebarPeekPointerRegion) {
        let before = machine.deadline
        machine.pointer(region, now: now())
        publish()
        if let deadline = machine.deadline, deadline != before {
            schedule(max(0, deadline.timeIntervalSince(now()))) { [weak self] in self?.tick() }
        }
    }

    /// Applies a pending open or close whose time has come.
    func tick() {
        if machine.tick(now: now()) { publish() }
    }

    private func publish() {
        if presentation != machine.presentation { presentation = machine.presentation }
    }
}
