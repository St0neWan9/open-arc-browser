import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// The Easel in the shell (B56). Acceptance: docs/arc-spec/06-flows.md §9 (observed: full-page
/// canvas, "Untitled Easel" title, toolbar select / image / text / circle / rectangle / arrow /
/// pen / capture with select highlighted by default, inert collaborator button, Share button in
/// the URL box), §4 (pinned row with an Easel icon), §8 (Library ▸ Easels: search, empty state),
/// 02-shortcuts.md (⌃⇧E New Easel), 01-menus.md (File ▸ New Easel). Gestures are inferred.
@MainActor
final class EaselShellTests: XCTestCase {
    private var fixture = SidebarFixture()
    private var counter = 7000
    private lazy var clock = fixture.now
    private let engine = FakeEngine()

    private func makeModel() -> ShellModel {
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: fixture.ws,
            now: { [unowned self] in self.clock },
            makeID: { [unowned self] in
                self.counter += 1
                return SidebarFixture.id(self.counter)
            }
        )
        model.selectSpace(fixture.home)
        return model
    }

    private func p(_ x: Double, _ y: Double) -> EaselPoint { EaselPoint(x: x, y: y) }

    private func drag(_ canvas: EaselCanvasModel, from a: EaselPoint, to b: EaselPoint) {
        canvas.pointerDown(at: a)
        canvas.pointerDragged(to: EaselPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        canvas.pointerUp(at: b)
    }

    // MARK: New Easel [06 §9, §4, 02]

    /// [02] ⌃⇧E / [01 §File] New Easel: an "Untitled Easel" pinned row with the Easel icon is
    /// selected, its canvas shows, and no engine page is made for it. [06 §9, §4] observed.
    func testNewEaselCreatesSelectedPinnedRowWithCanvas() async throws {
        let model = makeModel()
        let enginePages = engine.tabIDs.count
        let easelID = try XCTUnwrap(model.newEasel())
        let tabID = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(model.workspace.easelID(ofTab: tabID), easelID)
        XCTAssertEqual(model.workspace.tabs[tabID]?.location, .pinned(spaceID: fixture.home, folderID: nil))
        XCTAssertEqual(model.easelCanvas.easel?.title, "Untitled Easel")
        XCTAssertEqual(model.sidebar.selectedEaselID, easelID)
        XCTAssertTrue(model.sidebar.isEaselRow(tabID))
        XCTAssertFalse(model.sidebar.isEaselRow(fixture.pinnedTab))
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(engine.tabIDs.count, enginePages, "an Easel row never gets an engine page")
        // [06 §9] observed: the select tool is highlighted by default.
        XCTAssertEqual(model.easelCanvas.tool, .select)
        model.stop()
    }

    /// New Easel leaves the Library and the command bar.
    func testNewEaselLeavesLibrary() throws {
        let model = makeModel()
        model.openLibrary(.easels)
        XCTAssertNotNil(model.newEasel())
        XCTAssertFalse(model.isLibraryActive)
        model.stop()
    }

    /// The toolbar's tools in the observed order. [06 §9] observed.
    func testToolbarOrder() {
        XCTAssertEqual(EaselCanvasModel.Tool.allCases, [.select, .image, .text, .circle, .rectangle, .arrow, .pen, .capture])
    }

    // MARK: Drawing [06 §9]

    /// Each drawing tool adds its kind of element; shape tools return to select. inferred gestures.
    func testDrawEachShapeKind() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let canvas = model.easelCanvas

        canvas.selectTool(.rectangle)
        drag(canvas, from: p(100, 100), to: p(200, 180))
        XCTAssertEqual(canvas.tool, .select, "a shape tool is used once")
        canvas.selectTool(.circle)
        drag(canvas, from: p(300, 300), to: p(250, 220))
        canvas.selectTool(.arrow)
        drag(canvas, from: p(400, 400), to: p(500, 350))
        canvas.selectTool(.pen)
        canvas.pointerDown(at: p(600, 600))
        canvas.pointerDragged(to: p(610, 605))
        canvas.pointerDragged(to: p(630, 640))
        canvas.pointerUp(at: p(650, 650))
        XCTAssertEqual(canvas.tool, .pen, "the pen keeps drawing")

        let elements = model.workspace.elements(inEasel: easelID)
        XCTAssertEqual(elements.map(\.content.kind), [.rectangle, .circle, .arrow, .pen])
        XCTAssertEqual(elements[0].frame, EaselRect(x: 100, y: 100, width: 100, height: 80))
        XCTAssertEqual(elements[1].frame, EaselRect(x: 250, y: 220, width: 50, height: 80), "dragging up-left works")
        guard case .arrow(let start, let end) = elements[2].content else { return XCTFail("not an arrow") }
        XCTAssertEqual(EaselGeometry.denormalize(start, in: elements[2].frame), p(400, 400))
        XCTAssertEqual(EaselGeometry.denormalize(end, in: elements[2].frame), p(500, 350))
        guard case .pen(let points) = elements[3].content else { return XCTFail("not a pen stroke") }
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(elements[3].style, EaselTokens.defaultStyle(for: .pen))
        model.stop()
    }

    /// A click with a shape tool places a default-sized shape. inferred.
    func testClickPlacesDefaultShape() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        model.easelCanvas.selectTool(.circle)
        model.easelCanvas.pointerDown(at: p(300, 300))
        model.easelCanvas.pointerUp(at: p(300, 300))
        let frame = try XCTUnwrap(model.workspace.elements(inEasel: easelID).first?.frame)
        XCTAssertEqual(frame.width, Metrics.Easel.defaultShapeSize.width)
        XCTAssertEqual(frame.center, p(300, 300))
        model.stop()
    }

    // MARK: Text [06 §9]

    /// The text tool places a box and edits it; committing stores the text, empty text deletes.
    func testTextToolEditsAndCommits() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let canvas = model.easelCanvas
        canvas.selectTool(.text)
        canvas.pointerDown(at: p(120, 300))
        canvas.pointerUp(at: p(120, 300))
        let id = try XCTUnwrap(canvas.editingTextID)
        canvas.commitText(id, string: "Hello Easel", height: 30)
        XCTAssertNil(canvas.editingTextID)
        let element = try XCTUnwrap(model.workspace.easelElements[id])
        XCTAssertEqual(element.content, .text(string: "Hello Easel"))
        XCTAssertEqual(element.frame.height, 30)

        // Double-click edits again; clearing the text deletes the box.
        canvas.pointerDown(at: p(130, 300), clickCount: 2)
        XCTAssertEqual(canvas.editingTextID, id)
        canvas.commitText(id, string: "  ")
        XCTAssertTrue(model.workspace.elements(inEasel: easelID).isEmpty)
        model.stop()
    }

    // MARK: Select, move, resize, delete [06 §9]

    func testSelectMoveResizeDelete() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let canvas = model.easelCanvas
        canvas.selectTool(.rectangle)
        drag(canvas, from: p(100, 100), to: p(200, 200))
        let id = try XCTUnwrap(model.workspace.elements(inEasel: easelID).first?.id)
        XCTAssertEqual(canvas.selection, [id], "the new shape is selected")

        // Move: drag the body. The preview shows during the drag; one write at the end.
        canvas.pointerDown(at: p(150, 150))
        canvas.pointerDragged(to: p(170, 160))
        XCTAssertEqual(canvas.renderedElements.first?.frame, EaselRect(x: 120, y: 110, width: 100, height: 100))
        XCTAssertEqual(model.workspace.easelElements[id]?.frame.x, 100, "not stored mid-drag")
        canvas.pointerUp(at: p(180, 170))
        XCTAssertEqual(model.workspace.easelElements[id]?.frame, EaselRect(x: 130, y: 120, width: 100, height: 100))

        // Resize: drag the bottom-right handle.
        canvas.pointerDown(at: p(230, 220))
        canvas.pointerUp(at: p(260, 280))
        XCTAssertEqual(model.workspace.easelElements[id]?.frame, EaselRect(x: 130, y: 120, width: 130, height: 160))

        // A click on empty canvas clears the selection; ⌘A selects all; ⌫ deletes.
        canvas.pointerDown(at: p(900, 900))
        canvas.pointerUp(at: p(900, 900))
        XCTAssertTrue(canvas.selection.isEmpty)
        canvas.selectAll()
        XCTAssertEqual(canvas.selection, [id])
        canvas.deleteSelection()
        XCTAssertTrue(model.workspace.elements(inEasel: easelID).isEmpty)
        XCTAssertEqual(model.workspace.easelElements[id]?.meta.isTombstone, true)
        model.stop()
    }

    /// Resizing an arrow past its fixed corner mirrors its ends.
    func testResizeAcrossFlipsArrow() {
        let element = EaselElement(
            id: UUID(), easelID: UUID(), zKey: .initial, frame: EaselRect(x: 0, y: 0, width: 100, height: 100),
            content: .arrow(start: p(0, 0), end: p(1, 1)), style: EaselTokens.defaultStyle(for: .arrow), now: Date()
        )
        let result = EaselGeometry.resized(element.frame, handle: .bottomRight, to: p(-50, 50))
        XCTAssertEqual(result.frame, EaselRect(x: -50, y: 0, width: 50, height: 50))
        XCTAssertTrue(result.flipX)
        XCTAssertFalse(result.flipY)
        XCTAssertEqual(EaselGeometry.flipped(element.content, x: true, y: false), .arrow(start: p(1, 0), end: p(0, 1)))
    }

    func testHitTestingFollowsShapes() {
        func element(_ content: EaselElementContent) -> EaselElement {
            EaselElement(id: UUID(), easelID: UUID(), zKey: .initial, frame: EaselRect(x: 0, y: 0, width: 100, height: 100),
                         content: content, style: EaselTokens.defaultStyle(for: content.kind), now: Date())
        }
        let arrow = element(.arrow(start: p(0, 0), end: p(1, 1)))
        XCTAssertTrue(EaselGeometry.hits(arrow, at: p(50, 52)))
        XCTAssertFalse(EaselGeometry.hits(arrow, at: p(90, 10)), "far from the line")
        let circle = element(.circle)
        XCTAssertTrue(EaselGeometry.hits(circle, at: p(50, 50)))
        XCTAssertFalse(EaselGeometry.hits(circle, at: p(2, 2)), "outside the ellipse, inside the frame")
        XCTAssertTrue(EaselGeometry.hits(element(.rectangle), at: p(2, 2)))
    }

    // MARK: Images [06 §9]

    /// The image tool opens the picker and places the image centered in view, scaled down.
    func testImageToolPlacesPickedImage() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let canvas = model.easelCanvas
        let image = EaselImage(data: Data([1, 2, 3]), format: .png, pixelWidth: 960, pixelHeight: 480)
        canvas.pickImage = { image }
        canvas.visibleRect = { EaselRect(x: 0, y: 0, width: 1000, height: 800) }
        canvas.selectTool(.image)
        let element = try XCTUnwrap(model.workspace.elements(inEasel: easelID).first)
        XCTAssertEqual(element.content, .image(image))
        XCTAssertEqual(element.frame.width, Metrics.Easel.maxPlacedImageSide)
        XCTAssertEqual(element.frame.height, Metrics.Easel.maxPlacedImageSide / 2)
        XCTAssertEqual(element.frame.center, p(500, 400))
        XCTAssertEqual(canvas.tool, .select)
        // A cancelled picker adds nothing.
        canvas.pickImage = { nil }
        canvas.selectTool(.image)
        XCTAssertEqual(model.workspace.elements(inEasel: easelID).count, 1)
        model.stop()
    }

    /// ⌘V pastes an image, or text as a text box. Oversized images are refused.
    func testPasteImageAndText() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let canvas = model.easelCanvas
        canvas.readPasteboard = { .image(EaselImage(data: Data([9]), format: .jpeg, pixelWidth: 10, pixelHeight: 10)) }
        XCTAssertTrue(canvas.paste())
        canvas.readPasteboard = { .text("pasted") }
        XCTAssertTrue(canvas.paste())
        canvas.readPasteboard = { .image(EaselImage(data: Data(count: EaselImage.maxEncodedBytes + 1), format: .png, pixelWidth: 1, pixelHeight: 1)) }
        XCTAssertFalse(canvas.paste())
        XCTAssertEqual(model.workspace.elements(inEasel: easelID).map(\.content.kind), [.image, .text])
        model.stop()
    }

    func testImageEncoderFitsTheInlineLimit() throws {
        let size = NSSize(width: 2400, height: 1200)
        let image = NSImage(size: size, flipped: false) { rect in
            // Noise defeats compression, so the encoder has to scale and fall back to JPEG.
            var generator = SystemRandomNumberGenerator()
            for x in stride(from: 0, to: Int(rect.width), by: 8) {
                for y in stride(from: 0, to: Int(rect.height), by: 8) {
                    NSColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                            blue: .random(in: 0...1, using: &generator), alpha: 1).setFill()
                    NSRect(x: x, y: y, width: 8, height: 8).fill()
                }
            }
            return true
        }
        let encoded = try XCTUnwrap(EaselImageEncoder.encode(image))
        XCTAssertTrue(encoded.fitsInlineLimit)
        XCTAssertLessThanOrEqual(Double(max(encoded.pixelWidth, encoded.pixelHeight)), Metrics.Easel.maxStoredImagePixels)
        XCTAssertEqual(Double(encoded.pixelWidth) / Double(encoded.pixelHeight), 2, accuracy: 0.01)
    }

    // MARK: Title, rename [06 §9]

    /// [06 §9] observed: the title is editable; the sidebar row follows. Renaming the row renames
    /// the Easel too (inferred).
    func testTitleAndRowRenameStayInStep() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let tabID = try XCTUnwrap(model.selectedTabID)
        model.easelCanvas.renameTitle("Moodboard")
        XCTAssertEqual(model.workspace.easels[easelID]?.title, "Moodboard")
        XCTAssertEqual(model.workspace.tabs[tabID]?.displayTitle, "Moodboard")
        model.sidebar.commitRename(tabID, text: "Plans")
        XCTAssertEqual(model.workspace.easels[easelID]?.title, "Plans")
        XCTAssertEqual(model.workspace.tabs[tabID]?.displayTitle, "Plans")
        model.stop()
    }

    // MARK: Inert controls [06 §9]

    /// Capture, the collaborator button and Share do nothing (collaboration is out of scope).
    func testInertControls() throws {
        let model = makeModel()
        let easelID = try XCTUnwrap(model.newEasel())
        let before = model.workspace
        model.easelCanvas.selectTool(.capture)
        model.easelCanvas.inertCollaborationAction()
        XCTAssertEqual(model.easelCanvas.inertActionCount, 2)
        XCTAssertEqual(model.easelCanvas.tool, .select)
        XCTAssertEqual(model.workspace, before)
        XCTAssertNotNil(model.workspace.liveEasel(easelID))
        model.stop()
    }

    // MARK: Library ▸ Easels [06 §8, §11]

    /// [06 §8] observed: Library ▸ Easels lists Easels with a search field; a click opens one.
    func testLibraryListsSearchesAndOpensEasels() throws {
        let model = makeModel()
        XCTAssertTrue(model.library.easelResults.isEmpty, "empty state: Out of ideas!")
        let first = try XCTUnwrap(model.newEasel())
        model.easelCanvas.renameTitle("Moodboard")
        clock = clock.addingTimeInterval(10)
        let second = try XCTUnwrap(model.newEasel())
        model.easelCanvas.renameTitle("Trip Plan")
        XCTAssertEqual(model.library.easelResults.map(\.id), [second, first], "newest first")
        model.library.searchText[.easels] = "mood"
        XCTAssertEqual(model.library.easelResults.map(\.id), [first])
        model.library.searchText[.easels] = "zzz"
        XCTAssertTrue(model.library.easelResults.isEmpty)

        // Open from the Library: selects its existing row and leaves the Library.
        model.sidebar.selectTab(fixture.pinnedTab)
        model.openLibrary(.easels)
        let row = try XCTUnwrap(model.library.openEasel(first))
        XCTAssertFalse(model.isLibraryActive)
        XCTAssertEqual(model.selectedTabID, row)
        XCTAssertEqual(model.easelCanvas.easelID, first)
        model.stop()
    }

    /// [06 §11] observed: an Easel outlives its Space; opening it from the Library adds a row in
    /// the current Space.
    func testOpeningAnEaselWithoutRowAddsOne() throws {
        let model = makeModel()
        model.selectSpace(fixture.work)
        let easelID = try XCTUnwrap(model.newEasel())
        model.selectSpace(fixture.home)
        model.sidebar.requestDeleteSpace(fixture.work)
        model.sidebar.confirmDeleteSpace()
        XCTAssertTrue(model.workspace.tabs(showingEasel: easelID).isEmpty)
        XCTAssertEqual(model.library.easelResults.map(\.id), [easelID])

        let row = try XCTUnwrap(model.library.openEasel(easelID))
        XCTAssertEqual(model.workspace.tabs[row]?.location, .pinned(spaceID: fixture.home, folderID: nil))
        XCTAssertEqual(model.selectedTabID, row)
        model.library.deleteEasel(easelID)
        XCTAssertTrue(model.library.easelResults.isEmpty)
        XCTAssertNil(model.sidebar.selectedEaselID)
        model.stop()
    }

    /// An incognito window keeps nothing: no Easels. inferred.
    func testIncognitoHasNoEasels() {
        let model = makeModel()
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: model.controller)
        XCTAssertFalse(incognito.canCreateEasel)
        XCTAssertNil(incognito.newEasel())
        incognito.stop()
        model.stop()
    }
}
