import Foundation
import AppKit
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// Plan B51: the capture tools. Spec: docs/arc-spec/06-flows.md §24 (E4, observed unless noted):
/// §24.1 region capture (dim, drag, frozen selection, result menu, Copy → "Copied Image", Escape),
/// §24.2 full page (no selection, clipboard, "Screenshot Copied to Clipboard · Save"), §24.3
/// portrait mode (bubble first, then the clipboard and the same bar), and the entry points of
/// §12 (Site Control Center camera and full page buttons) and [01 §File] / [02] ⇧⌘2. design-tokens
/// `Metrics.Capture` for the placements.
@MainActor
final class PageCaptureTests: XCTestCase {
    private var model: ShellModel!
    private var pasteboard: RecordingCaptureImagePasteboard!
    private var tempDir: URL!

    override func setUp() async throws {
        model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                           now: { Date(timeIntervalSince1970: 0) })
        pasteboard = RecordingCaptureImagePasteboard()
        model.pageCapture.pasteboard = pasteboard
        model.pageCapture.toastDuration = 0
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("b51-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dir = tempDir!
        model.pageCapture.saveDirectory = { dir }
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var capture: PageCaptureModel { model.pageCapture }

    @discardableResult
    private func selectExampleTab() async throws -> FakeTab {
        let id = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.com" }?.id)
        try await model.activate(tabID: id)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private let page = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 06 §24.1: Capture… dims the page and waits; the drag selects; release freezes the image of
    /// exactly that rectangle and opens the menu; Copy writes it and shows "Copied Image" with the
    /// menu still open; Escape leaves without a trace.
    func testRegionCaptureFlow() async throws {
        let live = try await selectExampleTab()
        model.beginRegionCapture()
        XCTAssertEqual(capture.phase, .selecting)
        XCTAssertNil(capture.selection)
        capture.dragChanged(from: CGPoint(x: 400, y: 120), to: CGPoint(x: 250, y: 60), in: page)
        XCTAssertEqual(capture.selection, CGRect(x: 250, y: 60, width: 150, height: 60), "the drag works in any direction")
        capture.dragEnded(from: CGPoint(x: 400, y: 120), to: CGPoint(x: 250, y: 60), in: page)
        await capture.settle()
        XCTAssertEqual(capture.phase, .selected)
        XCTAssertEqual(live.commands.last, .capture(.visible(EngineRect(x: 250, y: 60, width: 150, height: 60))))
        let image = try XCTUnwrap(capture.regionImage)
        XCTAssertEqual([image.pixelWidth, image.pixelHeight], [150, 60], "the image matches the selection")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.pngData))
        var samples = [Int](repeating: 0, count: 4)
        rep.getPixel(&samples, atX: 0, y: 0)
        let expected = FakePageImage.color(atX: 250, y: 60)
        XCTAssertEqual(Array(samples[0..<3]), [Int(expected.red), Int(expected.green), Int(expected.blue)],
                       "the image's corner is the selection's corner of the page")

        capture.perform(.copy)
        XCTAssertEqual(pasteboard.written, [image.pngData])
        XCTAssertEqual(capture.toast, .copiedImage)
        XCTAssertEqual(capture.toast?.text, "Copied Image")
        XCTAssertEqual(capture.phase, .selected, "06 §24.1: the menu stays open after Copy")

        capture.cancel()
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertNil(capture.selection)
        XCTAssertNil(capture.regionImage)
    }

    /// 06 §24.1: a click is not a selection; Escape while selecting leaves.
    func testClickKeepsSelectingAndEscapeLeaves() async throws {
        try await selectExampleTab()
        model.beginRegionCapture()
        capture.dragEnded(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 12), in: page)
        await capture.settle()
        XCTAssertEqual(capture.phase, .selecting)
        XCTAssertNil(capture.selection)
        capture.cancel()
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertTrue(pasteboard.written.isEmpty)
    }

    /// Retake (inferred) goes back to selecting with the next page number; the drag is clipped
    /// to the page.
    func testRetakeAndClipping() async throws {
        try await selectExampleTab()
        model.beginRegionCapture()
        capture.dragEnded(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 900, y: 700), in: page)
        await capture.settle()
        XCTAssertEqual(capture.selection, CGRect(x: 700, y: 500, width: 100, height: 100))
        XCTAssertEqual(capture.selectionNumber, 1)
        capture.perform(.retake)
        XCTAssertEqual(capture.phase, .selecting)
        XCTAssertNil(capture.selection)
        XCTAssertEqual(capture.selectionNumber, 2)
    }

    /// 06 §24.1: the menu's items and order; only Copy, Save… and Retake act (the rest unknown).
    func testResultMenuItems() {
        XCTAssertEqual(PageCaptureMenuItem.allCases.map(\.title),
                       ["Save to Library", "Copy", "Save…", "Send via iMessage…", "Edit", "Retake", "New Easel"])
        XCTAssertEqual(PageCaptureMenuItem.allCases.filter(\.isAvailable), [.copy, .save, .retake])
        XCTAssertEqual(PageCaptureMenuItem.allCases.filter(\.startsGroup), [.edit, .newEasel])
    }

    /// Save… writes the frozen image where the panel says (a temp dir here).
    func testSaveWithPanel() async throws {
        try await selectExampleTab()
        let target = tempDir.appendingPathComponent("picked.png")
        var asked: (String, URL?)?
        capture.chooseSaveURL = { name, folder in
            asked = (name, folder)
            return target
        }
        model.beginRegionCapture()
        capture.dragEnded(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 30), in: page)
        await capture.settle()
        capture.perform(.save)
        await capture.settle()
        XCTAssertEqual(asked?.0, "Screenshot \(Self.localTime(Date(timeIntervalSince1970: 0))).png")
        XCTAssertEqual(asked?.1, tempDir)
        XCTAssertEqual(try Data(contentsOf: target), capture.regionImage?.pngData)
    }

    private static func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    /// 06 §24.1: the ⇧⌘ tip shows on the first region capture only.
    func testShortcutTipOnlyTheFirstTime() async throws {
        try await selectExampleTab()
        model.beginRegionCapture()
        XCTAssertTrue(capture.showsShortcutTip)
        capture.cancel()
        model.beginRegionCapture()
        XCTAssertFalse(capture.showsShortcutTip)
    }

    /// 06 §24.2: Capture Full Page has no selection step: the whole page goes to the clipboard and
    /// the bar shows; its Save writes into the save folder only when clicked.
    func testFullPageToClipboardAndSave() async throws {
        let live = try await selectExampleTab()
        live.simulateCaptureSizes(viewport: (800, 600), page: (800, 1800))
        model.captureFullPage()
        XCTAssertEqual(capture.phase, .idle, "no selection UI")
        await capture.settle()
        XCTAssertEqual(live.commands.last, .capture(.fullPage(maximumAspectRatio: nil)))
        XCTAssertEqual(pasteboard.written.count, 1)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pasteboard.written.first)))
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [800, 1800])
        XCTAssertEqual(capture.toast, .screenshotCopied)
        XCTAssertEqual(capture.toast?.text, "Screenshot Copied to Clipboard")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tempDir.path).isEmpty, "nothing saved before Save")
        capture.saveToastImage()
        let saved = try XCTUnwrap(capture.lastSavedURL)
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: saved), pasteboard.written.first)
        XCTAssertNil(capture.toast)
    }

    /// 06 §24.3: portrait mode shows its bubble first; the button copies the card and shows the bar.
    func testPortraitModeBubbleThenClipboard() async throws {
        let live = try await selectExampleTab()
        live.simulateCaptureSizes(viewport: (800, 600), page: (800, 3000))
        model.beginPortraitCapture()
        XCTAssertEqual(capture.phase, .portrait)
        XCTAssertTrue(pasteboard.written.isEmpty, "nothing copied before the button")
        await capture.settle()
        let preview = try XCTUnwrap(capture.portraitPage)
        XCTAssertEqual(preview.pixelWidth, 800)
        XCTAssertEqual(preview.pixelHeight, Int((800 * Metrics.Capture.portraitPageAspect).rounded(.down)))
        capture.confirmPortraitCapture()
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(capture.toast, .screenshotCopied)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pasteboard.written.first)))
        let margin = Int((800 * Metrics.Capture.portraitMarginRatio).rounded())
        XCTAssertEqual(rep.pixelsWide, 800 + 2 * margin)
        XCTAssertEqual(rep.pixelsHigh, preview.pixelHeight + 2 * margin)
    }

    /// 06 §12 / §24: the Site Control Center's camera and full page buttons start the captures.
    func testSiteControlCenterButtons() async throws {
        try await selectExampleTab()
        let sc = model.siteControls
        XCTAssertTrue(sc.canRunTools)
        sc.present()
        sc.run(.captureArea)
        XCTAssertEqual(capture.phase, .selecting)
        capture.cancel()
        sc.present()
        sc.run(.captureFullPage)
        await capture.settle()
        XCTAssertEqual(capture.toast, .screenshotCopied)
    }

    /// Switching tabs leaves a region capture (inferred).
    func testTabSwitchCancels() async throws {
        try await selectExampleTab()
        model.beginRegionCapture()
        let other = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.org" }?.id)
        try await model.activate(tabID: other)
        XCTAssertEqual(capture.phase, .idle)
    }

    /// design-tokens `Metrics.Capture`: hint card, result menu, selection label, toast and
    /// portrait bubble placement (06 §24.1–§24.3).
    func testPlacement() {
        typealias G = PageCaptureGeometry
        let panel = CGRect(x: 0, y: 0, width: 1634, height: 965)
        XCTAssertEqual(G.hintCardFrame(in: panel), CGRect(x: 632, y: 965 - 37 - 70, width: 370, height: 70))
        let selection = CGRect(x: 200, y: 150, width: 300, height: 200)
        XCTAssertEqual(G.resultMenuFrame(selection: selection, in: panel), CGRect(x: 513, y: 150, width: 273, height: 354))
        // No room on the right: the menu goes left of the selection (inferred).
        let right = CGRect(x: 1300, y: 150, width: 300, height: 200)
        XCTAssertEqual(G.resultMenuFrame(selection: right, in: panel).maxX, 1300 - 13)
        XCTAssertEqual(G.selectionLabelOrigin(selection: selection, in: panel), CGPoint(x: 175, y: 128))
        XCTAssertEqual(G.toastOrigin(size: CGSize(width: 317, height: 46), in: panel), CGPoint(x: 1634 - 8 - 317, y: 4))
        XCTAssertEqual(G.portraitBubbleFrame(in: panel), CGRect(x: 674, y: 359.5, width: 286, height: 246))
    }

    /// The capture items are off without a live page.
    func testNeedsALivePage() {
        XCTAssertFalse(model.canCapturePage)
        model.beginRegionCapture()
        XCTAssertEqual(capture.phase, .idle)
    }

    /// Save never overwrites: " 2", " 3"… before the extension.
    func testUniqueFileName() throws {
        let first = PageCaptureGeometry.uniqueURL(in: tempDir, name: "Shot.png")
        try Data([1]).write(to: first)
        XCTAssertEqual(PageCaptureGeometry.uniqueURL(in: tempDir, name: "Shot.png").lastPathComponent, "Shot 2.png")
    }
}
