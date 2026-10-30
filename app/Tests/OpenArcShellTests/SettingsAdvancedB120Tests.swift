import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B120: Settings ▸ Advanced shows Arc's three groups and the button row ([03 §Advanced]
/// observed; B100 capture), then one compact card of our own rows: ad blocking (C16, with a filter
/// ruleset), Check for Updates (D7) and crash reports (Q8). The automatic-update switch is only in
/// General ("Automatically update Open Arc", B100), never repeated here.
@MainActor
final class SettingsAdvancedB120Tests: XCTestCase {
    private var shells: [ShellModel] = []

    override func tearDown() async throws {
        shells.forEach { $0.stop() }
        shells = []
    }

    private func makeSettings() -> SettingsModel {
        let shell = ShellModel(dependencies: .fake(), workspace: .demo())
        shells.append(shell)
        return SettingsModel(shell: shell)
    }

    /// Arc's groups are unchanged; our rows are one card, in this order.
    func testOneExtraCardAfterArcsGroups() {
        XCTAssertEqual(AdvancedPane.cards.map(\.count), [2, 3, 3])
        XCTAssertEqual(AdvancedPane.extraRowIDs, ["advanced.adBlocking", "advanced.checkForUpdates", "advanced.showCrashReports"])
        for id in AdvancedPane.extraRowIDs {
            XCTAssertEqual(AdvancedPane.tile(id).color, SettingsTile.gray, id)
            XCTAssertNotNil(NSImage(systemSymbolName: AdvancedPane.tile(id).symbol, accessibilityDescription: nil), id)
        }
    }

    /// No update switch in Advanced (General has the one switch); the card keeps Check for
    /// Updates… and the crash reports button. The pane lays out with and without ad blocking.
    func testNoDuplicateUpdateSwitch() async throws {
        XCTAssertFalse(AdvancedPane.extraRowIDs.contains { $0.contains("automatic") })
        XCTAssertFalse(AdvancedPane.toggleIDs.contains { $0.contains("update") })
        XCTAssertTrue(SettingsCatalog.controls(in: .general).contains { $0.id == "general.automaticUpdates" })
        XCTAssertFalse(SettingsCatalog.controls(in: .advanced).contains { $0.label == UpdateStrings.automaticChecks || $0.label == UpdateStrings.automaticDownloads })
        XCTAssertEqual(SettingsCatalog.control("advanced.showCrashReports").kind, .button)
        let settings = makeSettings()
        for loaded in [false, true] {
            if loaded { await settings.loadAdBlocking() }
            let host = NSHostingView(rootView: AdvancedPane(model: settings).frame(width: SettingsTokens.windowWidth))
            host.frame = CGRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 900)
            host.layoutSubtreeIfNeeded()
        }
    }
}
