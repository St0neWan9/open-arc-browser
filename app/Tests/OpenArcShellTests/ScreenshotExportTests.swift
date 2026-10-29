import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign
@testable import OpenArcShell

/// Renders the main window offscreen to PNG files for visual review (plan B16).
/// Runs only when `OPENARC_SCREENSHOT_DIR` is set, so normal test runs write nothing.
@MainActor
final class ScreenshotExportTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["OPENARC_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func testExportMainWindowScreenshots() async throws {
        guard let dir = outputDirectory else { throw XCTSkip("OPENARC_SCREENSHOT_DIR not set") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        if let first = model.workspace.today(spaceID: spaceID).first {
            try await model.activate(tabID: first.id)
        }
        try render(model, to: dir.appendingPathComponent("01-main-window.png"))

        model.presentCommandBar(.newTab)
        model.commandBar.queryText = "exa"
        await model.commandBar.waitForRefresh()
        try render(model, to: dir.appendingPathComponent("02-command-bar.png"))
        model.dismissCommandBar()
    }

    /// B21: one light and one dark Space (the same purple theme, grain on), with the command bar
    /// open, for comparison with [04 §dark mode (E7)].
    func testExportLightAndDarkSpaceScreenshots() async throws {
        guard let dir = outputDirectory else { throw XCTSkip("OPENARC_SCREENSHOT_DIR not set") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        if let first = model.workspace.today(spaceID: spaceID).first {
            try await model.activate(tabID: first.id)
        }
        for appearance in [ThemeAppearance.light, .dark] {
            var draft = model.spaceFlow.themeDraft(of: spaceID)
            draft.appearance = appearance
            draft.colors = [RGBAColor(hex: 0x6B4FD8)]
            draft.grain = 0.5
            model.spaceFlow.applyThemeDraft(draft, to: spaceID)
            await model.controller.settleEngineWork()
            try render(model, to: dir.appendingPathComponent("b21-\(appearance.rawValue)-space.png"))
            model.presentCommandBar(.newTab)
            model.commandBar.queryText = "exa"
            await model.commandBar.waitForRefresh()
            try render(model, to: dir.appendingPathComponent("b21-\(appearance.rawValue)-command-bar.png"))
            model.dismissCommandBar()
        }
        model.stop()
    }

    /// B16: the E11 sample themes ([07 §8]: purple #A5729C, yellow #F8D55A, blue #6CBAD9) in light
    /// and dark, with the command bar; and the surfaces drawn by us at their measured sizes: the
    /// theme bubble, the New Folder and Delete Space sheets, the Library.
    func testExportE11Screenshots() async throws {
        guard let dir = outputDirectory else { throw XCTSkip("OPENARC_SCREENSHOT_DIR not set") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        if let first = model.workspace.today(spaceID: spaceID).first {
            try await model.activate(tabID: first.id)
        }
        let samples: [(String, UInt32)] = [("purple", 0xA5729C), ("yellow", 0xF8D55A), ("blue", 0x6CBAD9)]
        for (name, hex) in samples {
            for appearance in [ThemeAppearance.light, .dark] {
                var draft = model.spaceFlow.themeDraft(of: spaceID)
                draft.appearance = appearance
                draft.colors = [RGBAColor(hex: hex)]
                draft.grain = 0
                model.spaceFlow.applyThemeDraft(draft, to: spaceID)
                await model.controller.settleEngineWork()
                try render(model, to: dir.appendingPathComponent("b16-\(name)-\(appearance.rawValue).png"))
                if name == "purple" {
                    model.presentCommandBar(.newTab)
                    await model.commandBar.waitForRefresh()
                    try render(model, to: dir.appendingPathComponent("b16-\(name)-\(appearance.rawValue)-command-bar.png"))
                    model.dismissCommandBar()
                    let palette = model.windowPalette
                    try renderView(ThemeEditorView(theme: .constant(model.spaceFlow.themeDraft(of: spaceID))),
                                   size: ThemeEditorMetrics.size, to: dir.appendingPathComponent("b16-theme-bubble-\(appearance.rawValue).png"))
                    try renderView(SidebarNewFolderSheet(viewModel: model.sidebar),
                                   size: CGSize(width: 450, height: 222), to: dir.appendingPathComponent("b16-new-folder-\(appearance.rawValue).png"))
                    try renderView(DeleteSpaceSheet(spaceName: "Work", palette: palette, onCancel: {}, onDelete: {}),
                                   size: CGSize(width: 450, height: 273), to: dir.appendingPathComponent("b16-delete-space-\(appearance.rawValue).png"))
                }
            }
        }
        model.openLibrary(.archivedTabs)
        try render(model, to: dir.appendingPathComponent("b16-library.png"))
        model.exitLibrary()
        model.stop()
    }

    /// B100: every Settings pane (toolbar and pane, without the system title bar) for comparison
    /// with the B100 reference captures of Arc's light Settings window.
    func testExportSettingsPanes() throws {
        guard let dir = outputDirectory else { throw XCTSkip("OPENARC_SCREENSHOT_DIR not set") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let settings = SettingsModel(shell: model)
        let height = SettingsToolbarLayout.height + SettingsTokens.paneMinHeight
        for pane in SettingsPane.allCases {
            settings.selectedPane = pane
            try renderView(SettingsWindowView(model: settings), size: CGSize(width: SettingsTokens.windowWidth, height: height),
                           to: dir.appendingPathComponent("b100-\(pane.rawValue).png"))
        }
        model.stop()
    }

    private func renderView<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func render(_ model: ShellModel, to url: URL) throws {
        let size = CGSize(width: 1920, height: 985)
        let host = NSHostingView(rootView: MainWindowView(model: model).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
