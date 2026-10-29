import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B91 (f1-review-3 P3): modal cards centered in the window over a dimmed window, the Settings
/// window (always light since the user's 2026-10-28 decision), the Little Arc size. Spec:
/// docs/arc-spec/07-design-system.md §6, §11, §12.
/// Collects the top edges of rows in a laid-out view.
private struct RowTopsKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

@MainActor
final class WindowModalTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var models: [ShellModel] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows = []
        for model in models { model.stop() }
        models = []
    }

    // MARK: 07 §12 placement

    /// [07 §12] observed: New Folder / Rename (450 × 222) at (416, 289) in a 1281 × 801 window and
    /// at (275, 214) in 1000 × 650; Delete Space (450 × 273) at (416, 264).
    func testCardOriginMatchesObservedPlacements() {
        let folder = CGSize(width: 450, height: 222), delete = CGSize(width: 450, height: 273)
        XCTAssertEqual(WindowModalLayout.cardOrigin(windowSize: CGSize(width: 1281, height: 801), cardSize: folder), CGPoint(x: 416, y: 289))
        XCTAssertEqual(WindowModalLayout.cardOrigin(windowSize: CGSize(width: 1000, height: 650), cardSize: folder), CGPoint(x: 275, y: 214))
        XCTAssertEqual(WindowModalLayout.cardOrigin(windowSize: CGSize(width: 1281, height: 801), cardSize: delete), CGPoint(x: 416, y: 264))
        // Never off the window's top-left, even in a window smaller than the card.
        XCTAssertEqual(WindowModalLayout.cardOrigin(windowSize: CGSize(width: 300, height: 200), cardSize: folder), CGPoint(x: 0, y: 0))
    }

    /// [07 §12] observed in the real window: New Folder, Rename Space, Delete Space, Change Icon
    /// (Space and sidebar item) and the other cards show centered in the browser window at the two
    /// observed window sizes, with the window dimmed under them; no system sheet is attached.
    func testEveryCardIsCenteredInTheWindowOverTheDimmedWindow() throws {
        let cards: [(id: String, size: Size2D, open: (ShellModel) -> Void)] = [
            ("newFolder", Metrics.Dialog.newFolderSize, { $0.sidebar.requestNewFolder() }),
            ("renameSpace", Metrics.Dialog.newFolderSize, { $0.spaceFlow.beginRename(spaceID: $0.sidebar.selectedSpaceID!) }),
            ("deleteSpace", Metrics.Dialog.deleteSpaceSize, { $0.sidebar.requestDeleteSpace($0.sidebar.selectedSpaceID!) }),
            ("changeSpaceIcon", SpaceFlowLocalTokens.iconSheetSize, { $0.spaceFlow.beginChangeIcon(spaceID: $0.sidebar.selectedSpaceID!) }),
            ("changeItemIcon", SpaceFlowLocalTokens.iconSheetSize, { $0.sidebar.beginChangeIcon(SidebarFixture().folderA) }),
        ]
        for windowSize in [CGSize(width: 1281, height: 801), CGSize(width: 1000, height: 650)] {
            for card in cards {
                let (model, window, host) = makeWindow(size: windowSize)
                let before = brightness(pixel(host, at: CGPoint(x: 140, y: windowSize.height - 20)))
                XCTAssertNil(cardFrame(in: host, id: card.id), card.id)
                card.open(model)
                settle(host)
                let label = "\(card.id) at \(windowSize)"
                let frame = try XCTUnwrap(cardFrame(in: host, id: card.id), label)
                let expected = WindowModalLayout.cardFrame(windowSize: windowSize, cardSize: CGSize(width: card.size.width, height: card.size.height))
                XCTAssertEqual(frame.origin.x, expected.origin.x, accuracy: 0.5, label)
                XCTAssertEqual(frame.origin.y, expected.origin.y, accuracy: 0.5, label)
                XCTAssertEqual(frame.width, expected.width, accuracy: 0.5, label)
                XCTAssertEqual(frame.height, expected.height, accuracy: 0.5, label)
                XCTAssertNil(window.attachedSheet, label)
                // The window outside the card is darker than before: the veil. [07 §12] observed.
                let after = brightness(pixel(host, at: CGPoint(x: 140, y: windowSize.height - 20)))
                XCTAssertLessThan(after, before - 0.05, label)
            }
        }
    }

    /// The card goes away with its state.
    func testCardClosesWithItsState() {
        let (model, _, host) = makeWindow(size: CGSize(width: 1281, height: 801))
        model.sidebar.requestNewFolder()
        settle(host)
        XCTAssertNotNil(cardFrame(in: host, id: "newFolder"))
        model.sidebar.isNewFolderSheetPresented = false
        settle(host)
        XCTAssertNil(cardFrame(in: host, id: "newFolder"))
    }

    /// The veil is gray #B8B8B8 at ≈ 61 %. [07 §12] observed (2026-10-27 pixel samples).
    func testVeilIsAGrayTranslucentToken() {
        let dim = ThemeDerivation.windowModalDim
        XCTAssertEqual(dim.red, dim.green)
        XCTAssertEqual(dim.green, dim.blue)
        XCTAssertEqual(dim.red, Double(0xB8) / 255, accuracy: 0.001)
        XCTAssertEqual(dim.alpha, 0.61, accuracy: 0.001)
    }

    // MARK: Keyboard and focus

    /// [06 §3, §11] observed key caps: Esc cancels, Return confirms, through the card's own
    /// buttons now that the card is drawn in the window.
    func testEscapeCancelsAndReturnConfirms() throws {
        let (model, window, host) = makeWindow(size: CGSize(width: 1281, height: 801))
        model.sidebar.requestNewFolder()
        settle(host)
        XCTAssertTrue(host.performKeyEquivalent(with: key(WindowModalKeys.escapeKeyCode, "\u{1b}", window)))
        settle(host)
        XCTAssertFalse(model.sidebar.isNewFolderSheetPresented, "Esc: Cancel")

        let spaceCount = model.sidebar.workspace.allLiveSpaces.count
        let doomed = try XCTUnwrap(model.sidebar.selectedSpaceID)
        model.sidebar.requestDeleteSpace(doomed)
        settle(host)
        XCTAssertNotNil(model.sidebar.pendingSpaceDeletionID)
        XCTAssertTrue(host.performKeyEquivalent(with: key(WindowModalKeys.returnKeyCode, "\r", window)))
        settle(host)
        XCTAssertNil(model.sidebar.pendingSpaceDeletionID, "Return: Delete")
        XCTAssertEqual(model.sidebar.workspace.allLiveSpaces.count, spaceCount - 1)
    }

    /// The keys the card takes: plain Esc always, plain Return / Enter unless a text field has
    /// the keyboard (its submit runs), nothing while an input method composes or with modifiers.
    func testCardKeyRouting() {
        typealias K = WindowModalKeys
        XCTAssertTrue(K.routesToCard(keyCode: K.escapeKeyCode, flags: [], responder: .other))
        XCTAssertTrue(K.routesToCard(keyCode: K.escapeKeyCode, flags: [], responder: .textField(composing: false)))
        XCTAssertTrue(K.routesToCard(keyCode: K.returnKeyCode, flags: [], responder: .other))
        XCTAssertTrue(K.routesToCard(keyCode: K.enterKeyCode, flags: [.numericPad], responder: .other))
        XCTAssertFalse(K.routesToCard(keyCode: K.returnKeyCode, flags: [], responder: .textField(composing: false)))
        XCTAssertFalse(K.routesToCard(keyCode: K.escapeKeyCode, flags: [], responder: .textField(composing: true)))
        XCTAssertFalse(K.routesToCard(keyCode: K.returnKeyCode, flags: [.command], responder: .other))
        XCTAssertFalse(K.routesToCard(keyCode: 0, flags: [], responder: .other))
    }

    /// The New Folder field takes the keyboard when the card opens.
    func testTextFieldTakesFocus() {
        let (model, window, host) = makeWindow(size: CGSize(width: 1281, height: 801))
        model.sidebar.requestNewFolder()
        settle(host)
        settle(host)
        XCTAssertTrue(window.firstResponder is NSText, "field editor of the New Folder field")
    }

    // MARK: 07 §6 Settings window

    /// User decision (2026-10-28), not the spec: the Settings window is always light (Arc's was
    /// measured dark purple in [07 §6]; the user rejected it). B100: Arc's light Settings window is
    /// white (B100 capture, observed), so a dark system appearance is overridden, the window fill is
    /// white and the title bar is the system's opaque one without a separator (our toolbar draws
    /// its own hairline).
    func testSettingsWindowIsAlwaysLight() throws {
        XCTAssertEqual(SettingsPalette.window, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(ThemeDerivation.settingsAppearance, .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = false
        XCTAssertTrue(SettingsWindowConfigurator.apply(to: window, title: "General"))
        XCTAssertEqual(window.appearance?.name, .aqua)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertTrue(window.titlebarAppearsTransparent, "the white fill shows behind the title, B100 capture")
        XCTAssertEqual(window.titlebarSeparatorStyle, .none, "the toolbar draws its own hairline")
        XCTAssertEqual(window.title, "General", "the title follows the pane [03]")
        let fill = try XCTUnwrap(window.backgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(fill.redComponent, 1, accuracy: 0.002)
        XCTAssertEqual(fill.greenComponent, 1, accuracy: 0.002)
        XCTAssertEqual(fill.blueComponent, 1, accuracy: 0.002)
        XCTAssertFalse(SettingsWindowConfigurator.apply(to: window, title: "General"), "writes only what differs")
    }

    /// User decision (2026-10-28): the panes draw white under a dark system appearance, and the
    /// row text is Arc's dark gray (B100 capture, observed #4E4E4E), so it reads.
    func testSettingsPanesAreLightInDarkMode() throws {
        let shell = ShellModel(dependencies: .fake(), workspace: .demo())
        models.append(shell)
        let settings = SettingsModel(shell: shell)
        let view = SettingsPaneView(pane: .general, model: settings)
            .frame(width: SettingsTokens.windowWidth)
            .modifier(SettingsWindowChrome())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        // Bottom-left corner, outside the cards: the window fill.
        let corner = try XCTUnwrap(pixel(host, at: CGPoint(x: 4, y: 556)))
        XCTAssertGreaterThan(corner.redComponent, 0.98, "white, not dark")
        XCTAssertGreaterThan(corner.blueComponent, 0.98)
        XCTAssertLessThan(SettingsPalette.bodyText.red, 0.35, "dark row text on the white pane")
    }

    /// [07 §6] observed: 684 × 650 window, 56 pt toolbar, toggle rows 37 apart. The pane is sized
    /// under the title bar and toolbar, and a card of switch rows repeats at 37 pt.
    func testSettingsToolbarAndToggleRowPitch() {
        XCTAssertEqual(Metrics.Settings.toolbarHeight, 56)
        XCTAssertEqual(Metrics.Settings.toggleRowPitch, 37)
        XCTAssertEqual(SettingsToolbarLayout.height, 56)
        XCTAssertEqual(SettingsTokens.chromeHeight, CGFloat(Metrics.Settings.titleBarHeight) + 56)
        XCTAssertEqual(SettingsTokens.paneMinHeight, 650 - SettingsTokens.chromeHeight)

        let rows = (0..<4).map { i in SettingsToggleRow(label: "Toggle \(i)", isOn: .constant(i.isMultiple(of: 2))) }
        let view = SettingsCard {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SettingsDivider() }
                row.background(GeometryReader { proxy in
                    Color.clear.preference(key: RowTopsKey.self, value: [proxy.frame(in: .global).minY])
                })
            }
        }
        .frame(width: SettingsLayout.columnWidth)
        .modifier(SettingsWindowChrome())
        var tops: [CGFloat] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.onPreferenceChange(RowTopsKey.self) { tops = $0 })
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        XCTAssertEqual(tops.count, 4)
        let sorted = tops.sorted()
        for (lower, upper) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(upper - lower, 37, accuracy: 0.25) }
    }

    // MARK: 07 §11, §12 Little Arc

    /// [07 §11, §12] observed: the Little Arc window opens at 490 × 329, 20 pt from the screen's
    /// top-right corner.
    func testLittleArcInitialSize() {
        XCTAssertEqual(Metrics.LittleArc.initialSize, Size2D(width: 490, height: 329))
        XCTAssertEqual(Metrics.LittleArc.screenMargin, 20)
    }

    // MARK: Helpers

    private func makeWindow(size: CGSize) -> (ShellModel, NSWindow, NSView) {
        // Two Spaces, so Delete Space can run.
        let fixture = SidebarFixture()
        let model = ShellModel(dependencies: .fake(), workspace: fixture.ws, now: { fixture.now })
        models.append(model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: MainWindowView(model: model))
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        settle(host)
        return (model, window, host)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    private func key(_ code: UInt16, _ characters: String, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)!
    }

    private func subviews(of root: NSView, where match: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if match(view) { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The card's frame in window coordinates, top-left origin: the frame of the view the
    /// presenter puts behind the card (identifier "openarc.windowModal.<id>").
    private func cardFrame(in host: NSView, id: String) -> CGRect? {
        guard let marker = subviews(of: host, where: { $0.identifier?.rawValue == "openarc.windowModal.\(id)" }).first,
              let window = host.window else { return nil }
        let frame = marker.convert(marker.bounds, to: nil)
        return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The color drawn at `point` (top-left origin) of the hosting view.
    private func pixel(_ host: NSView, at point: CGPoint) -> NSColor? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    private func brightness(_ color: NSColor?) -> CGFloat {
        guard let color else { return -1 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    /// `color` drawn alone in a window, read back like `pixel`.
    private func renderedColor(_ color: Color) -> NSColor? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: color.frame(width: 40, height: 40))
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        return pixel(host, at: CGPoint(x: 20, y: 20))
    }
}
