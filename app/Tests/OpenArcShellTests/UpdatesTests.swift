import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// An update checker that records calls and never touches the network.
@MainActor
private final class FakeUpdateChecker: UpdateChecker {
    var unavailableReason: String?
    var canCheckForUpdates = false {
        didSet { canCheckForUpdatesDidChange?(canCheckForUpdates) }
    }
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var canCheckForUpdatesDidChange: (@MainActor (Bool) -> Void)?

    private(set) var startCount = 0
    private(set) var checkCount = 0
    /// The automatic-check value the checker had when `start()` ran.
    private(set) var automaticChecksAtStart: Bool?

    init(available: Bool = true) {
        unavailableReason = available ? nil : "not configured"
    }

    func start() {
        startCount += 1
        automaticChecksAtStart = automaticallyChecksForUpdates
        if unavailableReason == nil { canCheckForUpdates = true }
    }

    func checkForUpdates() { checkCount += 1 }
}

/// Software updates (plan D7). Spec: docs/arc-spec/01-menus.md §Arc ("Check for Updates…",
/// observed), 00-feature-inventory.md §自动更新 / §已定的服务策略 (Sparkle, static appcast host).
@MainActor
final class UpdatesTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
    }

    private func makeDefaults() -> UserDefaults {
        let name = "org.openarc.tests.updates.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeShell(checker: FakeUpdateChecker, preferences: AppPreferences = .inMemory()) -> ShellModel {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: preferences, updateChecker: checker)
        let now = Date(timeIntervalSince1970: 0)
        return ShellModel(dependencies: deps, workspace: .demo(now: now), now: { now })
    }

    // MARK: Model

    /// Stored choices reach the checker before it starts; defaults are checks on, downloads off.
    func testModelAppliesSettingsBeforeStarting() {
        let checker = FakeUpdateChecker()
        let model = UpdatesModel(checker: checker, preferences: .inMemory())
        XCTAssertEqual(checker.startCount, 1)
        XCTAssertEqual(checker.automaticChecksAtStart, true)
        XCTAssertTrue(checker.automaticallyChecksForUpdates)
        XCTAssertFalse(checker.automaticallyDownloadsUpdates)
        XCTAssertTrue(model.isAvailable)
        XCTAssertTrue(model.isCheckEnabled)
    }

    /// "Check for Updates…" forwards to the checker, and is ignored while a check runs.
    func testCheckForUpdatesFollowsCanCheck() {
        let checker = FakeUpdateChecker()
        let model = UpdatesModel(checker: checker, preferences: .inMemory())
        model.checkForUpdates()
        XCTAssertEqual(checker.checkCount, 1)
        checker.canCheckForUpdates = false
        XCTAssertFalse(model.canCheckForUpdates)
        XCTAssertFalse(model.isCheckEnabled)
        model.checkForUpdates()
        XCTAssertEqual(checker.checkCount, 1)
        checker.canCheckForUpdates = true
        XCTAssertTrue(model.isCheckEnabled)
    }

    /// An unconfigured build disables the check and explains why.
    func testUnavailableCheckerDisablesControls() {
        let checker = FakeUpdateChecker(available: false)
        let model = UpdatesModel(checker: checker, preferences: .inMemory())
        XCTAssertFalse(model.isAvailable)
        XCTAssertFalse(model.isCheckEnabled)
        XCTAssertEqual(model.unavailableReason, "not configured")
        model.checkForUpdates()
        XCTAssertEqual(checker.checkCount, 0)

        let none = UpdatesModel(checker: UnavailableUpdateChecker(), preferences: .inMemory())
        XCTAssertFalse(none.isCheckEnabled)
        XCTAssertNotNil(none.unavailableReason)
    }

    /// The two automatic-update choices persist per device and are applied to the checker.
    func testSettingsPersistAndReachChecker() {
        let defaults = makeDefaults()
        let checker = FakeUpdateChecker()
        let model = UpdatesModel(checker: checker, preferences: AppPreferences(defaults: defaults))
        model.automaticallyChecksForUpdates = false
        model.automaticallyDownloadsUpdates = true
        XCTAssertFalse(checker.automaticallyChecksForUpdates)
        XCTAssertTrue(checker.automaticallyDownloadsUpdates)

        // A new launch reads them back and hands them to its checker before starting it.
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.automaticallyChecksForUpdates)
        XCTAssertTrue(reloaded.automaticallyDownloadsUpdates)
        let next = FakeUpdateChecker()
        let nextModel = UpdatesModel(checker: next, preferences: reloaded)
        XCTAssertEqual(next.automaticChecksAtStart, false)
        XCTAssertTrue(next.automaticallyDownloadsUpdates)
        XCTAssertFalse(nextModel.automaticallyChecksForUpdates)
    }

    // MARK: Menu and Settings wiring

    /// [01 §Arc] observed title. The app menu and Settings share the controller's one model, built
    /// from the injected checker and started once.
    func testMenuAndSettingsShareTheControllerModel() {
        XCTAssertEqual(UpdateStrings.checkForUpdates, "Check for Updates…")
        let checker = FakeUpdateChecker()
        let shell = makeShell(checker: checker)
        let settings = SettingsModel(shell: shell)
        XCTAssertTrue(settings.updates === shell.controller.updates)
        XCTAssertTrue(settings.updates.checker === checker)
        XCTAssertEqual(checker.startCount, 1)

        // Settings' button and the menu item both call `UpdatesModel.checkForUpdates()`.
        settings.updates.checkForUpdates()
        shell.controller.updates.checkForUpdates()
        XCTAssertEqual(checker.checkCount, 2)
        XCTAssertEqual(checker.startCount, 1)

        settings.updates.automaticallyDownloadsUpdates = true
        XCTAssertTrue(checker.automaticallyDownloadsUpdates)
        XCTAssertTrue(shell.dependencies.preferences.automaticallyDownloadsUpdates)
        shell.stop()
    }

    /// The menu commands and the Settings section build with the fake checker.
    func testMenuAndSettingsViewsBuild() {
        let checker = FakeUpdateChecker()
        let model = UpdatesModel(checker: checker, preferences: .inMemory())
        _ = UpdateMenuItem(model: model).body
        let host = NSHostingView(rootView: Form { UpdateSettingsSection(model: model) }.formStyle(.grouped))
        host.frame = CGRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 300)
        host.layoutSubtreeIfNeeded()
    }

    /// The default dependencies never reach the network: their checker is unavailable.
    func testDefaultDependenciesCannotUpdate() {
        let deps = AppDependencies.fake()
        XCTAssertTrue(deps.updateChecker is UnavailableUpdateChecker)
        XCTAssertNotNil(deps.updateChecker.unavailableReason)
    }

    // MARK: Configuration

    private let validKey = Data(repeating: 7, count: 32).base64EncodedString()

    func testConfigurationRequiresBundleFeedAndRealKey() {
        let base: [String: Any] = [
            "CFBundleIdentifier": AppIdentity.bundleIdentifier,
            UpdateConfiguration.feedURLKey: "https://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/appcast.xml",
            UpdateConfiguration.publicKeyKey: validKey,
        ]
        XCTAssertEqual(UpdateConfiguration(infoDictionary: base), .ready(feedURL: UpdateConfiguration.hostedFeedURL))

        XCTAssertEqual(UpdateConfiguration(infoDictionary: [:]), .unavailable(.notAnAppBundle))
        var other = base; other["CFBundleIdentifier"] = "com.apple.dt.xctest.tool"
        XCTAssertEqual(UpdateConfiguration(infoDictionary: other), .unavailable(.notAnAppBundle))
        var noFeed = base; noFeed[UpdateConfiguration.feedURLKey] = nil
        XCTAssertEqual(UpdateConfiguration(infoDictionary: noFeed), .unavailable(.missingFeedURL))
        var http = base; http[UpdateConfiguration.feedURLKey] = "http://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/appcast.xml"
        XCTAssertEqual(UpdateConfiguration(infoDictionary: http), .unavailable(.missingFeedURL))
        var placeholder = base; placeholder[UpdateConfiguration.publicKeyKey] = UpdateConfiguration.placeholderPublicKey
        XCTAssertEqual(UpdateConfiguration(infoDictionary: placeholder), .unavailable(.missingPublicKey))
        var short = base; short[UpdateConfiguration.publicKeyKey] = Data(count: 16).base64EncodedString()
        XCTAssertEqual(UpdateConfiguration(infoDictionary: short), .unavailable(.missingPublicKey))
    }

    /// The development build never updates, even with a feed and a real key (plan B37).
    func testDevelopmentBuildHasNoUpdates() {
        let dev: [String: Any] = [
            "CFBundleIdentifier": AppIdentity.developmentBundleIdentifier,
            UpdateConfiguration.feedURLKey: "https://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/appcast.xml",
            UpdateConfiguration.publicKeyKey: validKey,
        ]
        XCTAssertEqual(UpdateConfiguration(infoDictionary: dev), .unavailable(.missingFeedURL))
        var foreign = dev; foreign["CFBundleIdentifier"] = "org.example.other"
        XCTAssertEqual(UpdateConfiguration(infoDictionary: foreign), .unavailable(.notAnAppBundle))
    }

    // MARK: Info.plist template

    private func bundleInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bundle/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The template carries Sparkle's keys: the hosted feed (D14) and the placeholder public key,
    /// so the app does not start Sparkle until a release key replaces it (docs/release.md).
    func testInfoPlistTemplateHasSparkleKeys() throws {
        let plist = try bundleInfoPlist()
        XCTAssertEqual(plist[UpdateConfiguration.feedURLKey] as? String, UpdateConfiguration.hostedFeedURL.absoluteString)
        XCTAssertEqual(plist[UpdateConfiguration.publicKeyKey] as? String, UpdateConfiguration.placeholderPublicKey)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(UpdateConfiguration(infoDictionary: plist), .unavailable(.missingPublicKey))
    }

    /// The template is the release build: its id, and exported drag types named `<id>.<name>`,
    /// the prefix make-app.sh --dev rewrites (plan B37).
    func testInfoPlistTemplateExportsTypesUnderTheReleaseIdentifier() throws {
        let plist = try bundleInfoPlist()
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.releaseBundleIdentifier)
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let ids = Set(exported.compactMap { $0["UTTypeIdentifier"] as? String })
        XCTAssertEqual(ids, ["\(AppIdentity.releaseBundleIdentifier).sidebar-item", "\(AppIdentity.releaseBundleIdentifier).library-space"])
    }
}
