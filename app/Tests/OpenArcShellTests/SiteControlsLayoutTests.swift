import XCTest
import SwiftUI
import AppKit
import OpenArcModel
@testable import OpenArcDesign
@testable import OpenArcShell

/// B90: the URL box anchor and the Site Control Center frames.
/// - `docs/arc-spec/07-design-system.md §12` observed (window 1281 × 801): the site controls icon is
///   30 × 30 at x 234–264, y 49–79; the bubble is 12 below it (y 91), centered on it, 236 wide,
///   ≈ 296 tall with two settings rows (AX 297), arrow on its top edge at the icon's center.
/// - `docs/arc-spec/04-visual-metrics.md §网页工具栏 (E16)` observed: window 262 × 280 around the
///   236 × 254 bubble (13 pt on every side), top buttons 48 × 32 at a 56 pt pitch.
@MainActor
final class SiteControlsLayoutTests: XCTestCase {
    private let referenceWindow = CGSize(width: 1281, height: 801)

    // MARK: Anchor

    /// [07 §12] observed: the icon box is 30 × 30 at x 234–264, y 49–79 for the URL box at
    /// x 8–268, y 46–82.
    func testURLBoxIconFrameMatchesReference() {
        let box = MainWindowLayout(windowSize: referenceWindow).addressFieldFrame
        XCTAssertEqual(box, CGRect(x: 8, y: 46, width: 260, height: 36))
        XCTAssertEqual(URLBoxIconLayout.siteControlsFrame(inURLBox: box), CGRect(x: 234, y: 49, width: 30, height: 30))
        XCTAssertEqual(URLBoxIconLayout.copyLinkFrame(inURLBox: box), CGRect(x: 204, y: 49, width: 30, height: 30))
        XCTAssertEqual(Metrics.SiteControls.urlBoxButtonSize, 30)
    }

    /// [07 §12] observed: the hosted icon row puts the real 30 × 30 button where the layout says.
    /// Every URL box path (with or without a Site Control Center model) builds this row.
    func testHostedIconButtonSitsAtTheMeasuredBox() throws {
        let box = MainWindowLayout(windowSize: referenceWindow).addressFieldFrame
        let probe = FrameProbe()
        let row = URLBoxIconRow {
            URLBoxIconButton(symbol: "link", label: "Copy link", id: URLBoxIconButton.copyLinkID, tint: .black) {}
        } siteControls: {
            URLBoxIconButton(symbol: "slider.horizontal.3", label: "Site controls", id: URLBoxIconButton.siteControlsID,
                             tint: .black) {}
                .background(FrameProbeView(probe: probe))
        }
        let host = NSHostingView(rootView: row.frame(width: box.width, height: box.height))
        host.frame = CGRect(origin: .zero, size: box.size)
        host.layoutSubtreeIfNeeded()
        let frame = try XCTUnwrap(probe.frame(in: host))
        let expected = URLBoxIconLayout.siteControlsFrame(inURLBox: box).offsetBy(dx: -box.minX, dy: -box.minY)
        XCTAssertEqual(frame, expected)
    }

    /// [07 §12] observed: the bubble (two settings rows, as in that capture) opens at y 91, 12 below
    /// the icon, centered on it, with its arrow at the icon's center: the old 24 pt box put it ≈ 3
    /// pt higher (y 88).
    func testBubbleSitsTwelveBelowTheIconCenteredOnIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: 199, y: 100, width: referenceWindow.width, height: referenceWindow.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let icon = URLBoxIconLayout.siteControlsFrame(inURLBox: MainWindowLayout(windowSize: referenceWindow).addressFieldFrame)
        let anchor = FloatingBubbleAnchor.AnchorView(frame: NSRect(x: icon.minX, y: referenceWindow.height - icon.maxY,
                                                                   width: icon.width, height: icon.height))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        let controller = FloatingBubbleController()
        controller.animates = false
        addTeardownBlock { @MainActor in
            controller.hide(animated: false)
            window.close()
            model.stop()
        }
        XCTAssertEqual(model.siteControls.settingRows.count, 2, "Developer Mode and Automatic Picture-In-Picture")

        controller.anchorView = anchor
        controller.request = siteControlsBubbleRequest(model.siteControls, palette: ThemeDerivation.palette(for: nil))
        controller.schedule()
        try await Task.sleep(nanoseconds: 50_000_000)
        let frame = try XCTUnwrap(controller.appliedFrame)
        XCTAssertEqual(frame.bubble, CGRect(x: 131, y: 91, width: 236, height: 296))
        XCTAssertEqual(frame.bubble.midX, icon.midX)
        XCTAssertEqual(frame.bubble.minY - icon.maxY, CGFloat(Metrics.FloatingBubble.gapBelow))
        XCTAssertEqual(frame.arrow, FloatingBubbleArrow(edge: .top, position: icon.midX - frame.bubble.minX))
    }

    // MARK: Bubble content

    /// [04 §网页工具栏 (E16)] observed: four 48 × 32 tool buttons at a 56 pt pitch, centered in
    /// the 236 pt bubble (10 pt each side).
    func testToolButtonsAre48By32AtA56Pitch() {
        let layout = SiteControlsLayout(extensionCount: 0, settingRowCount: 1)
        XCTAssertEqual(layout.toolFrames.map(\.size), Array(repeating: CGSize(width: 48, height: 32), count: 4))
        XCTAssertEqual(layout.toolFrames.map(\.minX), [10, 66, 122, 178])
        XCTAssertEqual(layout.toolFrames.first?.minY, 10)
        XCTAssertEqual(layout.width - (layout.toolFrames.last?.maxX ?? 0), layout.toolFrames.first?.minX)
    }

    /// [04 §网页工具栏 (E16)] observed: with one settings row (Developer Mode) and no extension the
    /// bubble is 236 × 254 in a 262 × 280 window (13 pt around it). [07 §12] observed ≈ 296 with
    /// two rows.
    func testBubbleSizesMatchBothCaptures() {
        let toolbarCase = SiteControlsLayout(extensionCount: 0, settingRowCount: 1)
        XCTAssertEqual(CGSize(width: toolbarCase.width, height: toolbarCase.height), CGSize(width: 236, height: 254))
        XCTAssertEqual(toolbarCase.referenceWindowSize, CGSize(width: 262, height: 280))
        XCTAssertEqual(Metrics.SiteControls.toolbarCaseBubbleSize, Size2D(width: 236, height: 254))
        let urlBoxCase = SiteControlsLayout(extensionCount: 0, settingRowCount: 2)
        XCTAssertEqual(urlBoxCase.height, 296)
    }

    /// [06 §17.3] observed: "+" is 48 × 32 like the tool buttons; extension buttons share its grid
    /// (inferred), wrapping after four and growing the bubble.
    func testExtensionGridWrapsOnTheToolGrid() {
        let one = SiteControlsLayout(extensionCount: 0, settingRowCount: 1)
        XCTAssertEqual(one.extensionCellFrame(index: 0).size, CGSize(width: 48, height: 32))
        let five = SiteControlsLayout(extensionCount: 4, settingRowCount: 1)
        XCTAssertEqual(five.extensionLines, 2)
        XCTAssertEqual(five.extensionCellFrame(index: 4).minX, five.toolFrames[0].minX)
        XCTAssertEqual(five.extensionCellFrame(index: 3).minX, five.toolFrames[3].minX)
        XCTAssertEqual(five.height - one.height, 32 + 8)
    }

    /// The hosted bubble view takes exactly the layout's size, so the measured and declared heights
    /// agree.
    func testHostedBubbleHasTheLayoutSize() {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        defer { model.stop() }
        let layout = model.siteControls.contentLayout
        let host = NSHostingView(rootView: SiteControlsView(model: model.siteControls))
        XCTAssertEqual(host.fittingSize, CGSize(width: layout.width, height: layout.height))
    }
}

/// Records the frame of the view it backs.
@MainActor
private final class FrameProbe {
    weak var view: NSView?
    func frame(in host: NSView) -> CGRect? {
        guard let view else { return nil }
        let rect = view.convert(view.bounds, to: host)
        // Top-left based, like the spec.
        return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct FrameProbeView: NSViewRepresentable {
    let probe: FrameProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
