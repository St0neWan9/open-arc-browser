import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B91 (f1-review-3 P3): modal cards centered in the window over a dimmed window, the always-dark
/// Settings window, the Little Arc size. Spec: docs/arc-spec/07-design-system.md §6, §11, §12.
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

    /// The veil is a gray translucent token; its strength is unknown in [07 §12] (not measured).
    func testVeilIsAGrayTranslucentToken() {
        let dim = ThemeDerivation.windowModalDim
        XCTAssertEqual(dim.red, dim.green)
        XCTAssertEqual(dim.green, dim.blue)
        XCTAssertGreaterThan(dim.alpha, 0)
        XCTAssertLessThan(dim.alpha, 1)
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

    /// [07 §6] observed: the Settings window is dark purple (≈ #241F29) and does not follow the
    /// system light appearance.
    func testSettingsWindowIsAlwaysDark() throws {
        XCTAssertEqual(ThemeDerivation.settingsWindowBackground, RGBAColor(hex: 0x241F29))
        XCTAssertEqual(ThemeDerivation.settingsAppearance, .dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(SettingsWindowConfigurator.apply(to: window))
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        let fill = try XCTUnwrap(window.backgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(fill.redComponent, 0x24 / 255, accuracy: 0.002)
        XCTAssertEqual(fill.greenComponent, 0x1F / 255, accuracy: 0.002)
        XCTAssertEqual(fill.blueComponent, 0x29 / 255, accuracy: 0.002)
        XCTAssertFalse(SettingsWindowConfigurator.apply(to: window), "writes only what differs")
    }

    /// [07 §6] observed: the panes draw the dark purple and stay dark under a light system
    /// appearance.
    func testSettingsPanesAreDarkPurpleInLightMode() throws {
        let shell = ShellModel(dependencies: .fake(), workspace: .demo())
        models.append(shell)
        let settings = SettingsModel(shell: shell)
        let view = SettingsPaneView(pane: .general, model: settings)
            .frame(width: SettingsTokens.windowWidth)
            .modifier(SettingsWindowChrome())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        // Bottom-left corner, outside the grouped sections: the window fill, compared with the
        // token drawn alone through the same readback (the cached bitmap is in the display's
        // color space, so the raw #241F29 reads slightly lighter).
        let corner = try XCTUnwrap(pixel(host, at: CGPoint(x: 4, y: 556)))
        let reference = try XCTUnwrap(renderedColor(ThemeDerivation.settingsWindowBackground.swiftUI))
        XCTAssertEqual(corner.redComponent, reference.redComponent, accuracy: 0.01)
        XCTAssertEqual(corner.greenComponent, reference.greenComponent, accuracy: 0.01)
        XCTAssertEqual(corner.blueComponent, reference.blueComponent, accuracy: 0.01)
        XCTAssertGreaterThan(corner.blueComponent, corner.greenComponent, "purple, not gray")
    }

    /// [07 §6] observed: 684 × 650 window, 56 pt toolbar, toggle rows 37 apart. The pane is sized
    /// under the title bar and toolbar, and the toggles of a grouped pane repeat at 37 pt.
    func testSettingsToolbarAndToggleRowPitch() {
        XCTAssertEqual(Metrics.Settings.toolbarHeight, 56)
        XCTAssertEqual(Metrics.Settings.toggleRowPitch, 37)
        XCTAssertEqual(SettingsTokens.chromeHeight, CGFloat(Metrics.Settings.titleBarHeight) + 56)
        XCTAssertEqual(SettingsTokens.paneMinHeight, 650 - SettingsTokens.chromeHeight)

        let view = Form {
            Section {
                ForEach(0..<4, id: \.self) { i in Toggle("Toggle \(i)", isOn: .constant(i.isMultiple(of: 2))) }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsTokens.windowWidth)
        .modifier(SettingsWindowChrome())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 562), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        settle(host)
        let tops = switchTops(in: host)
        XCTAssertEqual(tops.count, 4)
        for (lower, upper) in zip(tops, tops.dropFirst()) { XCTAssertEqual(upper - lower, 37, accuracy: 0.25) }
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

    /// Top edges of the switches (window coordinates), top to bottom.
    private func switchTops(in host: NSView) -> [CGFloat] {
        subviews(of: host) { String(describing: type(of: $0)) == "PlatformSwitch" || $0 is NSSwitch }
            .map { -$0.convert($0.bounds, to: nil).maxY }
            .sorted()
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
