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
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("b51-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var deps = AppDependencies.fake()
        deps.mediaFolders = LibraryMediaFolders(captures: tempDir.appendingPathComponent(LibraryMediaFolders.capturesFolderName)) { [] }
        model = ShellModel(dependencies: deps, workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                           now: { Date(timeIntervalSince1970: 0) })
        pasteboard = RecordingCaptureImagePasteboard()
        model.pageCapture.pasteboard = pasteboard
        model.pageCapture.toastDuration = 0
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

    /// 06 §24.1: the menu's items and order; every item acts in a normal window (B81).
    func testResultMenuItems() {
        XCTAssertEqual(PageCaptureMenuItem.allCases.map(\.title),
                       ["Save to Library", "Copy", "Save…", "Send via iMessage…", "Edit", "Retake", "New Easel"])
        XCTAssertEqual(PageCaptureMenuItem.allCases.filter { capture.canPerform($0) }, PageCaptureMenuItem.allCases)
        XCTAssertEqual(PageCaptureMenuItem.allCases.filter(\.startsGroup), [.edit, .newEasel])
    }

    /// A region captured from (0, 0) to (40, 30) of the example page, with the menu open.
    private func captureRegion() async throws -> EngineSnapshot {
        try await selectExampleTab()
        model.beginRegionCapture()
        capture.dragEnded(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 30), in: page)
        await capture.settle()
        XCTAssertEqual(capture.phase, .selected)
        return try XCTUnwrap(capture.regionImage)
    }

    /// B81, 06 §24.1 Save to Library (inferred: our captures folder): the image lands in the
    /// captures folder, "Saved to Library" shows, the menu stays, and Library ▸ Media lists the
    /// file as a screenshot.
    func testSaveToLibraryAppearsInMedia() async throws {
        let image = try await captureRegion()
        capture.perform(.saveToLibrary)
        let url = try XCTUnwrap(capture.lastLibraryURL)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, LibraryMediaFolders.capturesFolderName)
        XCTAssertEqual(try Data(contentsOf: url), image.pngData)
        XCTAssertEqual(capture.toast, .savedToLibrary)
        XCTAssertEqual(capture.toast?.text, "Saved to Library")
        XCTAssertEqual(capture.phase, .selected, "the menu stays, like Copy")

        capture.perform(.saveToLibrary)
        XCTAssertEqual(capture.lastLibraryURL?.lastPathComponent, (url.deletingPathExtension().lastPathComponent) + " 2.png",
                       "a second save never overwrites")

        capture.cancel()
        let library = model.library
        model.openLibrary(.media)
        library.dismissMediaIntro()
        await library.media.refresh().value
        let items = library.mediaPage.groups.flatMap(\.items)
        let saved = try XCTUnwrap(items.first { $0.url.lastPathComponent == url.lastPathComponent })
        XCTAssertEqual(saved.kind, .screenshot)
        XCTAssertEqual(items.count, 2)
        model.exitLibrary()
    }

    /// B81 Send via iMessage… (inferred: the Messages share service): the image is written to a
    /// file that goes to Messages, and the capture ends. When Messages is unavailable the capture
    /// stays and the error is kept.
    func testSendViaMessages() async throws {
        let handoff = tempDir.appendingPathComponent("handoff")
        capture.handoffDirectory = { handoff }
        var sent: [URL] = []
        capture.sendViaMessages = { url in sent.append(url); return false }
        let image = try await captureRegion()
        capture.perform(.sendViaMessages)
        XCTAssertEqual(capture.phase, .selected)
        XCTAssertNotNil(capture.lastError)

        capture.sendViaMessages = { url in sent.append(url); return true }
        capture.perform(.sendViaMessages)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.deletingLastPathComponent().standardizedFileURL.path, handoff.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(sent.last)), image.pngData)
        XCTAssertEqual(capture.phase, .idle)
    }

    /// B81 Edit (inferred: Preview): the image file opens in the editor and the capture ends.
    func testEditOpensTheImage() async throws {
        let handoff = tempDir.appendingPathComponent("handoff")
        capture.handoffDirectory = { handoff }
        var opened: [URL] = []
        capture.openInEditor = { opened.append($0); return true }
        let image = try await captureRegion()
        capture.perform(.edit)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(opened.first)), image.pngData)
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertTrue(model.workspace.easels.isEmpty, "Edit makes no Easel")
    }

    /// B81 + New Easel (inferred): a new Easel with its pinned row in the current Space, the image
    /// on it at the selection's size, selected; the capture ends.
    func testNewEaselPlacesTheImage() async throws {
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        _ = try await captureRegion()
        let easelID = try XCTUnwrap(capture.placeRegionOnNewEasel())
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(capture.lastEaselID, easelID)
        XCTAssertEqual(model.workspace.liveEasel(easelID)?.title, Easel.defaultTitle)
        XCTAssertEqual(model.sidebar.selectedEaselID, easelID, "the new Easel is shown")
        XCTAssertEqual(model.workspace.tabs[try XCTUnwrap(model.selectedTabID)]?.location.spaceID, spaceID)
        let elements = model.workspace.elements(inEasel: easelID)
        XCTAssertEqual(elements.count, 1)
        let element = try XCTUnwrap(elements.first)
        guard case .image(let placed) = element.content else { return XCTFail("an image element") }
        XCTAssertEqual([placed.pixelWidth, placed.pixelHeight], [40, 30])
        XCTAssertEqual(element.frame, EaselRect(x: (800 - 40) / 2, y: SidebarViewModel.placedImageTop, width: 40, height: 30),
                       "the selection's size, centered across the page under the title")
        XCTAssertNil(capture.placeRegionOnNewEasel(), "no capture runs any more")
    }

    /// B81: New Easel is off in an incognito window (it keeps no Easels).
    func testNewEaselNeedsANormalWindow() {
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: model.controller)
        defer { incognito.stop() }
        XCTAssertFalse(incognito.pageCapture.canPerform(.newEasel))
        XCTAssertTrue(incognito.pageCapture.canPerform(.copy))
    }

    /// 06 §24.4 (tip text observed, behavior inferred): a ⇧⌘ drag on the page starts a region
    /// capture with that drag as the selection, without the first-run tip, and its release
    /// captures it as a normal drag does.
    func testShiftCommandDragStartsRegionCapture() async throws {
        let live = try await selectExampleTab()
        XCTAssertTrue(capture.canStartShortcutCapture)
        XCTAssertTrue(capture.beginShortcutDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 105), in: page))
        XCTAssertEqual(capture.phase, .selecting)
        XCTAssertFalse(capture.showsShortcutTip, "the shortcut is what the tip teaches")
        XCTAssertEqual(capture.selection, CGRect(x: 100, y: 100, width: 10, height: 5))
        XCTAssertFalse(capture.canStartShortcutCapture, "one capture at a time")
        capture.shortcutDragChanged(to: CGPoint(x: 160, y: 140), in: page)
        XCTAssertEqual(capture.selection, CGRect(x: 100, y: 100, width: 60, height: 40))
        capture.shortcutDragEnded(at: CGPoint(x: 180, y: 150), in: page)
        await capture.settle()
        XCTAssertEqual(capture.phase, .selected)
        XCTAssertEqual(live.commands.last, .capture(.visible(EngineRect(x: 100, y: 100, width: 80, height: 50))))
        XCTAssertNil(capture.shortcutDragStart)
    }

    /// 06 §24.4: only ⇧⌘ (no ⌥ or ⌃) counts, and a press is a drag after a few points.
    func testShortcutModifiersAndThreshold() {
        XCTAssertTrue(PageCaptureShortcut.matches([.shift, .command]))
        XCTAssertTrue(PageCaptureShortcut.matches([.shift, .command, .capsLock]))
        XCTAssertFalse(PageCaptureShortcut.matches([.command]))
        XCTAssertFalse(PageCaptureShortcut.matches([.shift, .command, .option]))
        XCTAssertFalse(PageCaptureShortcut.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)))
        XCTAssertTrue(PageCaptureShortcut.isDrag(from: .zero, to: CGPoint(x: 4, y: 0)))
    }

    /// 06 §24.4: no ⇧⌘ capture without a live page.
    func testShortcutNeedsALivePage() {
        XCTAssertFalse(capture.canStartShortcutCapture)
        XCTAssertFalse(capture.beginShortcutDrag(from: .zero, to: CGPoint(x: 20, y: 20), in: page))
        XCTAssertEqual(capture.phase, .idle)
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
