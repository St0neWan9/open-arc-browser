import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B34: hidden-sidebar peek. docs/arc-spec/06-flows.md §14, observed with real mouse events:
/// hidden = no sidebar, no traffic lights, web panel with a ≈ 5 pt border; the pointer at the
/// window's left edge (x 0–2) floats the sidebar out over the page (inset ≈ 5 pt, rounded,
/// shadowed, deeper fill, traffic lights back) without resizing the page; "Hide sidebar" reads
/// "Lock sidebar" there and pins the sidebar back; leaving collapses it within ≈ 0.2 s.
@MainActor
final class SidebarPeekTests: XCTestCase {
    private let reference = CGSize(width: 1920, height: 985)
    private let t0 = Date(timeIntervalSince1970: 1000)

    /// A fake clock that jumps forward to each scheduled deadline and runs the work at once.
    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 0)
    }

    private func runTimersImmediately(_ peek: SidebarPeekController) {
        let clock = FakeClock()
        peek.now = { clock.now }
        peek.schedule = { delay, work in
            clock.now = clock.now.addingTimeInterval(delay)
            work()
        }
    }

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)), now: { Date(timeIntervalSince1970: 0) })
    }

    // MARK: State machine (injected clock)

    func testMachineOpensFromEdgeAfterDelayAndCollapsesAfterLeaving() {
        let timing = SidebarPeekTiming(openDelay: 0.05, closeDelay: 0.1)
        var m = SidebarPeekMachine(isPinned: false, timing: timing)
        XCTAssertEqual(m.presentation, .hidden)

        // Over the page: nothing.
        m.pointer(.outside, now: t0)
        XCTAssertNil(m.deadline)

        // At the edge: opens once the delay passed.
        m.pointer(.edge, now: t0)
        XCTAssertEqual(m.presentation, .hidden)
        XCTAssertFalse(m.tick(now: t0.addingTimeInterval(0.04)))
        XCTAssertTrue(m.tick(now: t0.addingTimeInterval(0.05)))
        XCTAssertEqual(m.presentation, .peeking)

        // Inside the overlay: stays open for as long as the pointer is there.
        m.pointer(.overlay, now: t0.addingTimeInterval(1))
        XCTAssertNil(m.deadline)
        XCTAssertFalse(m.tick(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(m.presentation, .peeking)

        // Out to the page: collapses after the close delay, well within 0.2 s.
        let leave = t0.addingTimeInterval(61)
        m.pointer(.outside, now: leave)
        XCTAssertFalse(m.tick(now: leave.addingTimeInterval(0.05)))
        XCTAssertTrue(m.tick(now: leave.addingTimeInterval(0.1)))
        XCTAssertEqual(m.presentation, .hidden)
    }

    func testMachineReturningBeforeCloseKeepsItOpenAndLeavingEdgeEarlyCancelsOpen() {
        var m = SidebarPeekMachine(isPinned: false, timing: SidebarPeekTiming(openDelay: 0.1, closeDelay: 0.1))
        // A brush past the edge does not open it.
        m.pointer(.edge, now: t0)
        m.pointer(.outside, now: t0.addingTimeInterval(0.05))
        XCTAssertFalse(m.tick(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(m.presentation, .hidden)

        m.pointer(.edge, now: t0.addingTimeInterval(2))
        m.tick(now: t0.addingTimeInterval(2.1))
        XCTAssertEqual(m.presentation, .peeking)
        // Out and back in before the close delay: still open.
        m.pointer(.outside, now: t0.addingTimeInterval(3))
        m.pointer(.overlay, now: t0.addingTimeInterval(3.05))
        XCTAssertFalse(m.tick(now: t0.addingTimeInterval(4)))
        XCTAssertEqual(m.presentation, .peeking)
    }

    func testMachineZeroDelayOpensImmediatelyAndLockPins() {
        var m = SidebarPeekMachine(isPinned: false, timing: SidebarPeekTiming(openDelay: 0, closeDelay: 0.1))
        m.pointer(.edge, now: t0)
        XCTAssertEqual(m.presentation, .peeking)
        // "Lock sidebar": pinned; the pointer no longer matters.
        m.pin()
        XCTAssertEqual(m.presentation, .pinned)
        m.pointer(.outside, now: t0)
        XCTAssertFalse(m.tick(now: t0.addingTimeInterval(10)))
        XCTAssertEqual(m.presentation, .pinned)
        m.pointer(.edge, now: t0)
        XCTAssertEqual(m.presentation, .pinned)
        m.hide()
        XCTAssertEqual(m.presentation, .hidden)
    }

    /// The controller schedules the pending change through its injected scheduler and clock.
    func testControllerUsesInjectedClockAndScheduler() {
        var clock = t0
        var pending: [(TimeInterval, @MainActor () -> Void)] = []
        let c = SidebarPeekController(
            isPinned: false, timing: SidebarPeekTiming(openDelay: 0.05, closeDelay: 0.1),
            now: { clock }, schedule: { pending.append(($0, $1)) }
        )
        c.pointerMoved(to: CGPoint(x: 1, y: 500), windowSize: reference)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].0, 0.05, accuracy: 0.0001)
        clock = clock.addingTimeInterval(0.05)
        pending.removeFirst().1()
        XCTAssertEqual(c.presentation, .peeking)

        // Inside the panel: no timer.
        c.pointerMoved(to: CGPoint(x: 150, y: 500), windowSize: reference)
        XCTAssertTrue(pending.isEmpty)
        // Over the page: collapses when the timer fires.
        c.pointerMoved(to: CGPoint(x: 900, y: 500), windowSize: reference)
        XCTAssertEqual(pending.count, 1)
        clock = clock.addingTimeInterval(0.1)
        pending.removeFirst().1()
        XCTAssertEqual(c.presentation, .hidden)

        // Leaving the window counts as outside.
        c.pointerMoved(to: CGPoint(x: 0, y: 10), windowSize: reference)
        clock = clock.addingTimeInterval(0.05)
        pending.removeFirst().1()
        XCTAssertEqual(c.presentation, .peeking)
        c.pointerMoved(to: nil, windowSize: reference)
        clock = clock.addingTimeInterval(0.1)
        pending.removeFirst().1()
        XCTAssertEqual(c.presentation, .hidden)
    }

    func testLocalTimingCollapsesWithinMeasuredBound() {
        // [06 §14] observed: collapsed within ≈ 0.2 s of leaving.
        XCTAssertLessThanOrEqual(SidebarPeekTokens.closeDelay + SidebarPeekTokens.slideDuration, 0.2)
        XCTAssertGreaterThanOrEqual(SidebarPeekTokens.openDelay, 0)
    }

    // MARK: Layout at 1920 × 985

    func testOverlayFrameAt1920x985() {
        let layout = SidebarPeekLayout(windowSize: reference)
        // [06 §14] observed: ≈ 5 pt from the top, bottom and left; width inferred.
        XCTAssertEqual(layout.panelFrame, CGRect(x: 5, y: 5, width: 271, height: 975))
        XCTAssertEqual(layout.panelFrame.minX, SidebarPeekTokens.panelInset)
        XCTAssertEqual(reference.height - layout.panelFrame.maxY, SidebarPeekTokens.panelInset)
        // The sidebar inside keeps its window position, so the top bar stays on the traffic lights.
        XCTAssertEqual(layout.sidebarSize, CGSize(width: 276, height: 980))
        // Hot zone x 0–2. [06 §14] observed.
        XCTAssertEqual(layout.region(of: CGPoint(x: 0, y: 500), presentation: .hidden), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: 2, y: 500), presentation: .hidden), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: 3, y: 500), presentation: .hidden), .outside)
        XCTAssertEqual(layout.region(of: CGPoint(x: 200, y: 500), presentation: .hidden), .outside)
        XCTAssertEqual(layout.region(of: CGPoint(x: 200, y: 500), presentation: .peeking), .overlay)
        XCTAssertEqual(layout.region(of: CGPoint(x: 280, y: 500), presentation: .peeking), .outside)
    }

    func testPanelFillIsDeeperAndMoreSaturated() {
        let window = ThemeDerivation.lightWindow(RGBAColor(hex: 0x8E6FD8))
        let fill = SidebarPeekTokens.panelFill(for: window)
        XCTAssertLessThan(ThemeDerivation.luminance(fill), ThemeDerivation.luminance(window))
        func spread(_ c: RGBAColor) -> Double { max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) }
        XCTAssertGreaterThan(spread(fill), spread(window))
    }

    // MARK: Shell integration

    func testWebPanelFrameUnchangedWhilePeeking() {
        let model = makeModel()
        model.toggleSidebar()
        let hidden = model.windowLayout(size: reference).webPanelFrame
        XCTAssertEqual(hidden, CGRect(x: 10, y: 10, width: 1900, height: 965))
        runTimersImmediately(model.sidebarPeek)
        model.sidebarPeek.pointerMoved(to: CGPoint(x: 1, y: 500), windowSize: reference)
        XCTAssertEqual(model.sidebarPresentation, .peeking)
        XCTAssertTrue(model.showsSidebarPeek)
        XCTAssertEqual(model.windowLayout(size: reference).webPanelFrame, hidden)
        XCTAssertFalse(model.isSidebarVisible)
        model.stop()
    }

    func testButtonLabelPerState() {
        // [06 §14] observed: "Hide sidebar" pinned, "Lock sidebar" in the overlay.
        XCTAssertEqual(SidebarPresentation.pinned.sidebarButtonLabel, "Hide sidebar")
        XCTAssertEqual(SidebarPresentation.peeking.sidebarButtonLabel, "Lock sidebar")
        XCTAssertEqual(SidebarPresentation.hidden.sidebarButtonLabel, "Hide sidebar")

        let model = makeModel()
        XCTAssertEqual(model.sidebarPresentation.sidebarButtonLabel, "Hide sidebar")
        model.toggleSidebar()
        runTimersImmediately(model.sidebarPeek)
        model.sidebarPeek.pointer(.edge)
        XCTAssertEqual(model.sidebarPresentation.sidebarButtonLabel, "Lock sidebar")
        // The View menu keeps "Show Sidebar" while peeking.
        XCTAssertEqual(model.sidebarToggleTitle, "Show Sidebar")
        // Clicking "Lock sidebar" goes through the same request as the hide button: pinned again.
        model.sidebar.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertEqual(model.sidebarPresentation, .pinned)
        XCTAssertEqual(model.sidebarPresentation.sidebarButtonLabel, "Hide sidebar")
        XCTAssertEqual(model.sidebarToggleTitle, "Hide Sidebar")
        XCTAssertFalse(model.tracksSidebarPeek)
        model.stop()
    }

    func testTrafficLightVisibilityPerState() {
        XCTAssertTrue(SidebarPresentation.pinned.showsWindowButtons)
        XCTAssertFalse(SidebarPresentation.hidden.showsWindowButtons)
        XCTAssertTrue(SidebarPresentation.peeking.showsWindowButtons)

        let model = makeModel()
        XCTAssertTrue(model.showsWindowButtons)
        model.toggleSidebar()
        XCTAssertFalse(model.showsWindowButtons)
        XCTAssertTrue(model.tracksSidebarPeek)
        runTimersImmediately(model.sidebarPeek)
        model.sidebarPeek.pointer(.edge)
        XCTAssertTrue(model.showsWindowButtons)
        model.toggleSidebar()
        XCTAssertTrue(model.showsWindowButtons)
        model.stop()
    }

    /// The configurator hides and shows the real window buttons.
    func testConfiguratorHidesWindowButtons() {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        XCTAssertTrue(MainWindowChromeConfigurator.Coordinator.applyVisibility(to: window, showsButtons: false))
        XCTAssertTrue(types.allSatisfy { window.standardWindowButton($0)?.isHidden == true })
        XCTAssertFalse(MainWindowChromeConfigurator.Coordinator.applyVisibility(to: window, showsButtons: false), "settled")
        XCTAssertTrue(MainWindowChromeConfigurator.Coordinator.applyVisibility(to: window, showsButtons: true))
        XCTAssertTrue(types.allSatisfy { window.standardWindowButton($0)?.isHidden == false })
    }

    /// Smoke test: the window lays out with the floating sidebar out.
    func testMainWindowContentLaysOutWhilePeeking() {
        let model = makeModel()
        model.toggleSidebar()
        runTimersImmediately(model.sidebarPeek)
        model.sidebarPeek.pointer(.edge)
        let host = NSHostingView(rootView: MainWindowContent(model: model, sidebar: model.sidebar))
        host.frame = CGRect(origin: .zero, size: reference)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.size, reference)
        model.stop()
    }
}
