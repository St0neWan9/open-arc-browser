import XCTest
import SwiftUI
import AppKit
import OpenArcDesign
@testable import OpenArcShell

/// B54: hiding the sidebar, per docs/arc-spec/06-flows.md §26 (E10), observed: the traffic
/// lights leave the window with the sidebar (close x 12 → −274, y 16 → 21 in window coordinates)
/// and are never drawn over the web panel; the peek opens only from the x = 0 column; inside the
/// floating sidebar the lights sit 5 pt right and down of their pinned spot (close (17, 21)).
/// With the web toolbar on, the toolbar's show-sidebar button leads instead (06 §17.2).
@MainActor
final class SidebarHideChromeTests: XCTestCase {
    private let reference = CGSize(width: 1920, height: 985)

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)), now: { Date(timeIntervalSince1970: 0) })
    }

    // MARK: Geometry (06 §26.1, §26.2)

    func testButtonFramesPerPlacementMatch06Section26() {
        // Pinned: [07 §2] observed (12, 16).
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, placement: .pinned).origin, CGPoint(x: 12, y: 16))
        // Hidden: 06 §26.1 observed close x −274 (= 12 − 286), y 21 (screen y 51 − 30).
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, placement: .hidden).origin, CGPoint(x: -274, y: 21))
        // Peek: 06 §26.2 observed close (17, 21).
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, placement: .peek).origin, CGPoint(x: 17, y: 21))
        // The Library spot is unchanged ([07 §2]).
        XCTAssertEqual(WindowChromeLayout.buttonFrame(index: 0, placement: .library).origin, CGPoint(x: 15, y: 20))
        // All three hidden buttons are fully outside the window.
        for index in 0..<3 {
            XCTAssertLessThan(WindowChromeLayout.buttonFrame(index: index, placement: .hidden).maxX, 0)
        }
        // The hidden-to-peek travel equals the floating panel's ([07 §11] x −291 → 0), so the
        // lights and the panel slide together.
        let travel = WindowChromeLayout.buttonFrame(index: 0, placement: .peek).minX
            - WindowChromeLayout.buttonFrame(index: 0, placement: .hidden).minX
        XCTAssertEqual(travel, SidebarPeekTokens.collapsedOffset)
        XCTAssertEqual(SidebarPeekTokens.collapsedOffset, 291)
    }

    /// 06 §26.2: the floating sidebar is the pinned one moved by (5, 5); its "Lock sidebar"
    /// button lands at x 82 (77 + 5), next to the lights.
    func testPeekPanelCarriesTheSidebarBy5x5() {
        let layout = SidebarPeekLayout(windowSize: reference)
        XCTAssertEqual(layout.panelFrame.origin, CGPoint(x: 5, y: 5))
        XCTAssertEqual(layout.sidebarSize.width, CGFloat(Metrics.Sidebar.width))
        XCTAssertEqual(layout.panelFrame.minX + CGFloat(Metrics.Sidebar.hideSidebarButtonX), 82)
        XCTAssertEqual(WindowButtonPlacement.peek.offset, CGSize(width: 5, height: 5))
    }

    /// 06 §26.2: x = 0 opens the peek; x = 1–5 never does.
    func testHotZoneIsTheFirstColumnOnly() {
        XCTAssertEqual(SidebarPeekTokens.edgeHotZoneWidth, 1)
        let layout = SidebarPeekLayout(windowSize: reference)
        XCTAssertEqual(layout.region(of: CGPoint(x: 0, y: 400), presentation: .hidden), .edge)
        for x in 1...5 {
            XCTAssertEqual(layout.region(of: CGPoint(x: CGFloat(x), y: 400), presentation: .hidden), .outside, "x \(x)")
        }
    }

    // MARK: Model (06 §26, §17.2)

    func testPlacementFollowsSidebarState() {
        let model = makeModel()
        XCTAssertEqual(model.windowButtonPlacement, .pinned)
        model.toggleSidebar()
        XCTAssertEqual(model.windowButtonPlacement, .hidden, "06 §26.2: no traffic lights while hidden")
        // A fake clock that jumps to each scheduled deadline and runs the work at once.
        var clock = Date(timeIntervalSince1970: 10)
        model.sidebarPeek.now = { clock }
        model.sidebarPeek.schedule = { delay, work in
            clock = clock.addingTimeInterval(delay)
            work()
        }
        model.sidebarPeek.pointer(.edge)
        XCTAssertEqual(model.sidebarPresentation, .peeking)
        XCTAssertEqual(model.windowButtonPlacement, .peek, "06 §26.2: back inside the floating panel")
        model.sidebarPeek.pointer(.outside)
        XCTAssertEqual(model.windowButtonPlacement, .hidden)
        model.toggleSidebar()
        XCTAssertEqual(model.windowButtonPlacement, .pinned)
        model.stop()
    }

    /// 06 §17.2: toolbar on and sidebar hidden: the lights are out of the window and the
    /// toolbar leads with the show-sidebar button.
    func testToolbarModeKeepsLightsOutAndShowSidebarFirst() {
        let model = makeModel()
        model.toggleWebToolbar()
        defer { if model.isWebToolbarShown { model.toggleWebToolbar() } }
        model.toggleSidebar()
        XCTAssertEqual(model.windowButtonPlacement, .hidden)
        XCTAssertEqual(model.webToolbarItems(role: .page).leading.first, .showSidebar)
        model.toggleSidebar()
        XCTAssertEqual(model.windowButtonPlacement, .pinned)
        XCTAssertNotEqual(model.webToolbarItems(role: .page).leading.first, .showSidebar)
        model.stop()
    }

    /// The lights move on the curve of the surface they follow; the slide curve stays the B40
    /// token (06 §26.1: unknown).
    func testMotionPerMove() {
        XCTAssertEqual(WindowButtonPlacement.motion(from: .pinned, to: .hidden), Motion.sidebarToggle)
        XCTAssertEqual(WindowButtonPlacement.motion(from: .hidden, to: .pinned), Motion.sidebarToggle)
        XCTAssertEqual(WindowButtonPlacement.motion(from: .peek, to: .pinned), Motion.sidebarToggle)
        XCTAssertEqual(WindowButtonPlacement.motion(from: .hidden, to: .peek), Motion.sidebarPeekSlide)
        XCTAssertEqual(WindowButtonPlacement.motion(from: .peek, to: .hidden), Motion.sidebarPeekSlide)
        XCTAssertNil(WindowButtonPlacement.motion(from: .pinned, to: .library))
        XCTAssertNil(WindowButtonPlacement.motion(from: nil, to: .hidden))
        XCTAssertNil(WindowButtonPlacement.motion(from: .pinned, to: .pinned))
    }

    // MARK: Real window

    private final class Box: ObservableObject {
        @Published var placement: WindowButtonPlacement = .pinned
    }

    private struct Root: View {
        @ObservedObject var box: Box
        var body: some View {
            Color.gray.background(MainWindowChromeConfigurator(placement: box.placement))
        }
    }

    private func center(_ type: NSWindow.ButtonType, in window: NSWindow) -> CGPoint? {
        guard let button = window.standardWindowButton(type) else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        return CGPoint(x: rect.midX, y: window.frame.height - rect.midY)
    }

    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private func assertCenters(_ window: NSWindow, dx: CGFloat, dy: CGFloat, hidden: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for (index, type) in types.enumerated() {
            guard let c = center(type, in: window) else { return XCTFail("no \(type)", file: file, line: line) }
            XCTAssertEqual(c.x, 20 + CGFloat(index) * 23 + dx, accuracy: 0.5, "\(type) x", file: file, line: line)
            XCTAssertEqual(c.y, 24 + dy, accuracy: 0.5, "\(type) y", file: file, line: line)
            XCTAssertEqual(window.standardWindowButton(type)?.isHidden, hidden, "\(type) hidden", file: file, line: line)
        }
    }

    /// 06 §26.1, §26.2 on a real window: hide sends the lights out (and hides them), the peek
    /// brings them in at +5/+5, pinning puts them back; the window settles after each move.
    func testRealWindowLightsLeaveAndReturnWithTheSidebar() async throws {
        let box = Box()
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Root(box: box))
        window.orderFront(nil)
        defer { window.close() }

        try await spin(0.3)
        assertCenters(window, dx: 0, dy: 0, hidden: false)

        box.placement = .hidden
        try await spin(0.4)
        assertCenters(window, dx: -286, dy: 5, hidden: true)

        box.placement = .peek
        try await spin(0.4)
        assertCenters(window, dx: 5, dy: 5, hidden: false)

        box.placement = .hidden
        try await spin(0.4)
        assertCenters(window, dx: -286, dy: 5, hidden: true)

        // A resize makes AppKit lay the title bar out again: the lights stay out and hidden.
        window.setContentSize(CGSize(width: 1400, height: 820))
        try await spin(0.3)
        assertCenters(window, dx: -286, dy: 5, hidden: true)
        XCTAssertFalse(MainWindowChromeConfigurator.Coordinator.needsLayout(window, placement: .hidden))

        box.placement = .pinned
        try await spin(0.4)
        assertCenters(window, dx: 0, dy: 0, hidden: false)
        XCTAssertFalse(MainWindowChromeConfigurator.Coordinator.apply(to: window, placement: .pinned), "settled")
    }
}
