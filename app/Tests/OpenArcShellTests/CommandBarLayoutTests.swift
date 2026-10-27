import XCTest
import SwiftUI
import AppKit
import OpenArcDesign
@testable import OpenArcShell

/// Geometry against the design tokens. [07 §5] observed: panel 765 × 327 pt with five results at
/// y 324, #F9F9F9 panel, no scrim, input row 64, results from +68 at a 50 pt pitch (fill 46).
final class CommandBarLayoutTests: XCTestCase {
    /// [07 §5] observed 765 × 327.
    func testPanelSizeWithFiveResultsMatchesMeasuredPanel() {
        let layout = CommandBarLayout(presentation: .window, resultCount: 5)
        XCTAssertEqual(layout.panelWidth, 765)
        XCTAssertEqual(layout.panelHeight, 327)
        XCTAssertEqual(layout.panelWidth, Metrics.CommandBar.width)
        XCTAssertEqual(layout.panelHeight, Metrics.CommandBar.heightWithFiveResults)
    }

    /// The existing `MainWindowLayout.commandBarFrame` and this layout must agree for 1 or more rows.
    func testHeightAgreesWithMainWindowLayoutForOneOrMoreRows() {
        let window = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        for n in [1, 2, 5, 6, 8] {
            XCTAssertEqual(CommandBarLayout(resultCount: n).panelHeight, window.commandBarFrame(resultCount: n).height, "rows: \(n)")
            XCTAssertEqual(CommandBarLayout(resultCount: n).panelWidth, window.commandBarFrame(resultCount: n).width)
        }
    }

    /// With no results only the input row remains (64), in both layouts. [07 §5] inferred from
    /// 64 + 4 + 5 × 50 + 9 = 327.
    func testEmptyResultListIsJustTheInputRow() {
        XCTAssertEqual(CommandBarLayout(resultCount: 0).panelHeight, Metrics.CommandBar.inputRowHeight)
        let window = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        XCTAssertEqual(window.commandBarFrame(resultCount: 0).height, Metrics.CommandBar.inputRowHeight)
    }

    /// [07 §5] observed: rows of 50 from +68 (y 392 in the window), x 7.5 inset; fill 46.
    func testRowFramesUseRowHeightAndPitch() {
        let layout = CommandBarLayout(resultCount: 5)
        let c = Metrics.CommandBar.self
        XCTAssertEqual(layout.inputRowFrame.height, 64)
        for i in 0..<5 {
            let f = layout.rowFrame(at: i)
            XCTAssertEqual(f.height, 50)
            XCTAssertEqual(f.minY, 68 + Double(i) * c.resultRowPitch)
            XCTAssertEqual(f.minX, 7.5)
            XCTAssertEqual(layout.rowFillFrame(at: i).height, 46)
        }
        XCTAssertEqual(layout.rowFrame(at: 1).minY - layout.rowFrame(at: 0).minY, c.resultRowPitch)
        // The last row plus the bottom padding closes the panel exactly.
        XCTAssertEqual(layout.rowFrame(at: 4).maxY + CommandBarLayout.bottomPadding, layout.panelHeight)
        XCTAssertGreaterThan(CommandBarLayout.bottomPadding, 0)
    }

    /// [04 §command bar] observed row geometry.
    func testRowsNeverOverlap() {
        let layout = CommandBarLayout(resultCount: 8)
        for i in 1..<8 { XCTAssertLessThanOrEqual(layout.rowFrame(at: i - 1).maxY, layout.rowFrame(at: i).minY) }
    }

    /// [06 §5] pane width 400; [06 §7] Little Arc initial size; [07 §11, §12] observed 490 x 329.
    func testPaneAndLittleArcSizes() {
        XCTAssertEqual(CommandBarLayout(presentation: .pane, resultCount: 5).panelWidth, Metrics.SplitView.paneCommandBarWidth)
        let little = CommandBarLayout(presentation: .littleArc, resultCount: 3)
        XCTAssertEqual(little.panelSize, CGSize(width: 490, height: 329))
        XCTAssertEqual(CommandBarLayout(presentation: .littleArc, resultCount: 9).panelSize, little.panelSize)
    }

    /// [07 §5] observed: x 577.5–1342.5, y 324–651 in the 1920 × 985 window.
    func testWindowPlacementIsCenteredAndAboveMiddle() {
        let container = CGSize(width: 1920, height: 985)
        let frame = CommandBarLayout(resultCount: 5).panelFrame(in: container)
        XCTAssertEqual(frame, CGRect(x: 577.5, y: 324, width: 765, height: 327))
        XCTAssertEqual(frame.midX, container.width / 2, accuracy: 0.01)
        XCTAssertLessThan(frame.midY, container.height / 2)
        XCTAssertEqual(frame, MainWindowLayout(windowSize: container).commandBarFrame(resultCount: 5))
    }

    /// [06 §5] observed: in a pane the bar sits at the lower right and stays inside the pane.
    func testPanePlacementIsLowerRightInsidePane() {
        let pane = CGSize(width: 800, height: 600)
        let frame = CommandBarLayout(presentation: .pane, resultCount: 5).panelFrame(in: pane)
        XCTAssertLessThanOrEqual(frame.maxX, pane.width)
        XCTAssertLessThanOrEqual(frame.maxY, pane.height)
        XCTAssertGreaterThan(frame.midX, pane.width / 2)
        XCTAssertGreaterThan(frame.midY, pane.height / 2)
    }

    /// [04 §command bar] robustness, inferred.
    func testPanelNeverExceedsSmallContainers() {
        let frame = CommandBarLayout(resultCount: 5).panelFrame(in: CGSize(width: 500, height: 200))
        XCTAssertLessThanOrEqual(frame.width, 500)
        XCTAssertLessThanOrEqual(frame.height, 200)
    }

    /// [07 §5] observed: the backdrop is not dimmed; #F9F9F9 panel; radius ≈ 11.
    func testNoScrimAndNearWhitePanelToken() {
        XCTAssertFalse(Metrics.CommandBar.dimsBackground)
        XCTAssertEqual(Metrics.CommandBar.cornerRadius, 11)
        let palette = ThemeDerivation.palette(for: nil)
        XCTAssertGreaterThan(ThemeDerivation.luminance(palette.commandBarBackground), 0.85)
    }

    /// [07 §5] observed: the input field (656 × 23 at panel (52.5, 20)), the ⓘ button (26 at
    /// 20.5 from the right) and the arrow box (24, 15 from the row's right) fit their rows.
    func testInputRowAndRowPartsFit() {
        let c = Metrics.CommandBar.self
        XCTAssertLessThan(c.inputFieldTop + c.inputFieldHeight, c.inputRowHeight)
        XCTAssertEqual(c.width - c.infoButtonTrailing - c.infoButtonSize, 1296 - 577.5)
        XCTAssertLessThan(c.resultArrowBoxSize, c.resultRowHeight)
        XCTAssertLessThan(c.resultIconSize, c.resultRowHeight)
        XCTAssertEqual(Typography.commandBarInput.lineHeight, c.inputFieldHeight)
    }
}

@MainActor
final class CommandBarRenderingTests: XCTestCase {
    /// Builds the view over FakeEngine-backed demo content and lays it out; the hosting view must
    /// size itself to the measured panel (five results → 765 × 327). [07 §5]
    func testViewRendersAtMeasuredPanelSizeWithFakeEngineContent() async throws {
        let model = await CommandBarPreviewSupport.makeViewModel()
        XCTAssertEqual(model.results.count, 5)
        let host = NSHostingView(rootView: CommandBarView(viewModel: model))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        XCTAssertEqual(fitting.width, 765, accuracy: 1)
        XCTAssertEqual(fitting.height, 327, accuracy: 1)
    }

    /// [06 §6, §7, §5] window, pane and Little Arc presentations.
    func testAllPresentationsRenderWithoutCrashing() async throws {
        for presentation in [CommandBarPresentation.window, .pane, .littleArc] {
            let model = await CommandBarPreviewSupport.makeViewModel(presentation: presentation)
            let host = NSHostingView(rootView: CommandBarView(viewModel: model))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
            host.layoutSubtreeIfNeeded()
            let layout = CommandBarLayout(presentation: presentation, resultCount: model.results.count)
            XCTAssertEqual(host.fittingSize.width, layout.panelWidth, accuracy: 1, "\(presentation)")
        }
    }
}
