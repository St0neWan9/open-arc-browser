import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Settings ▸ General / Advanced / Icon leftovers (plan B84).
/// Spec: docs/arc-spec/03-settings.md §General, §Advanced, §Icon; 06-flows.md §13.
@MainActor
final class SettingsB84Tests: XCTestCase {
    private var suiteNames: [String] = []
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
    }

    private func makePreferences() -> (AppPreferences, String) {
        let name = "org.openarc.tests.b84.\(UUID().uuidString)"
        suiteNames.append(name)
        return (AppPreferences(defaults: UserDefaults(suiteName: name)!), name)
    }

    private func makeShell(
        preferences: AppPreferences = .inMemory(),
        feedback: RecordingFeedbackOutput = RecordingFeedbackOutput(),
        icons: RecordingAppIconDisplay = RecordingAppIconDisplay(),
        picker: CancelledExportPicker = CancelledExportPicker(),
        workspace: WorkspaceState? = nil
    ) -> ShellModel {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: preferences,
                                   feedbackOutput: feedback, appIconDisplay: icons, exportPicker: picker)
        let now = clock
        return ShellModel(dependencies: deps, workspace: workspace ?? .demo(now: now), now: { now })
    }

    // MARK: [03 §General] Previews Settings…

    /// "Previews Settings…" opens the Links pane, where the Peek switches are (target inferred).
    func testPreviewsSettingsOpensLinksPane() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        settings.selectedPane = .general
        XCTAssertTrue(SettingsCatalog.control("general.previewsSettings").isEnabled)
        settings.openPreviewsSettings()
        XCTAssertEqual(settings.selectedPane, .links)
        shell.stop()
    }

    // MARK: [03 §Advanced] toggles: defaults and persistence

    /// Sound effects, reorder haptics and window dragging are on by default and persist per device.
    func testAdvancedTogglesDefaultOnAndPersist() {
        let (preferences, _) = makePreferences()
        let settings = AdvancedBehaviorSettings(preferences: preferences)
        XCTAssertTrue(settings.playsSoundEffects)
        XCTAssertTrue(settings.playsReorderHaptics)
        XCTAssertTrue(settings.allowsWindowDragFromPageTop)
        settings.playsSoundEffects = false
        settings.playsReorderHaptics = false
        settings.allowsWindowDragFromPageTop = false
        let reread = AdvancedBehaviorSettings(preferences: preferences)
        XCTAssertFalse(reread.playsSoundEffects)
        XCTAssertFalse(reread.playsReorderHaptics)
        XCTAssertFalse(reread.allowsWindowDragFromPageTop)
    }

    /// The Settings window and every browser window share one settings object (the controller's).
    func testAdvancedSettingsSharedWithWindows() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        XCTAssertTrue(settings.advancedBehavior === shell.controller.feedback.settings)
        let incognito = shell.controller.makeIncognito()
        XCTAssertTrue(incognito.feedback === shell.controller.feedback)
        XCTAssertTrue(incognito.appIcon === shell.controller.appIcon)
        shell.stop()
    }

    // MARK: [03 §Advanced] Play sound effects

    /// Copy URL and Clear Today play our own sounds while the switch is on, and none when off.
    func testSoundEffectsFollowToggle() throws {
        let output = RecordingFeedbackOutput()
        let shell = makeShell(feedback: output)
        let tab = try XCTUnwrap(shell.workspace.tabs.values.first { $0.location.isPinned == false && !$0.meta.isTombstone })
        shell.sidebar.selectTab(tab.id)
        shell.copySelectedURL()
        XCTAssertEqual(output.sounds, [.copy])
        shell.controller.feedback.settings.playsSoundEffects = false
        shell.copySelectedURL()
        XCTAssertEqual(output.sounds, [.copy])
        shell.controller.feedback.settings.playsSoundEffects = true
        shell.sidebar.clearToday()
        XCTAssertEqual(output.sounds, [.copy, .clear])
        // Nothing left to clear: no sound.
        shell.sidebar.clearToday()
        XCTAssertEqual(output.sounds, [.copy, .clear])
        shell.stop()
    }

    /// The sounds are synthesized (not bundled or copied): valid 16-bit mono WAVs, short, not
    /// silent, and different from each other. [00 §音效与触感]: Arc's sound content is not copied.
    func testSynthesizedSoundsAreShortValidWAVs() {
        var seen: Set<Data> = []
        for sound in FeedbackSound.allCases {
            let wav = FeedbackSoundSynth.wav(for: sound)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            let samples = FeedbackSoundSynth.samples(for: sound)
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
            let seconds = Double(samples.count) / Double(FeedbackSoundSynth.sampleRate)
            XCTAssertLessThan(seconds, 0.3, "\(sound)")
            XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 1_000, "\(sound)")
            XCTAssertNotNil(NSSound(data: wav), "\(sound)")
            seen.insert(wav)
        }
        XCTAssertEqual(seen.count, FeedbackSound.allCases.count)
    }

    // MARK: [03 §Advanced] Haptic feedback when reordering tabs

    /// Moving a drag to a new drop position taps once while the switch is on, never when off.
    func testReorderHapticOnDropFollowsToggle() {
        let f = SidebarFixture()
        let output = RecordingFeedbackOutput()
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), feedbackOutput: output),
            workspace: f.ws, now: { f.now }
        )
        let vm = SidebarViewModel(controller: controller, selectedSpaceID: f.home)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(.row(f.folderA, .above)))
        XCTAssertTrue(vm.performDrop(on: .row(f.folderA, .above)))
        XCTAssertEqual(output.haptics, 1)
        XCTAssertTrue(output.sounds.isEmpty)

        controller.feedback.settings.playsReorderHaptics = false
        vm.beginDrag(.tab(f.today2))
        XCTAssertTrue(vm.updateDropTarget(.row(f.folderA, .above)))
        XCTAssertTrue(vm.performDrop(on: .row(f.folderA, .above)))
        XCTAssertEqual(output.haptics, 1)
        vm.stop()
        controller.stop()
    }

    // MARK: [03 §Advanced] window dragging, [06 §13] drag strip

    /// The strip is centered at the top of the page area; off, it has no frame.
    func testWindowDragStripFrame() {
        let layout = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        let page = layout.pageFrame
        let strip = layout.windowDragStripFrame(isEnabled: true)
        XCTAssertEqual(strip.midX, page.midX, accuracy: 0.01)
        XCTAssertEqual(strip.minY, page.minY, accuracy: 0.01)
        XCTAssertEqual(strip.size, MainWindowLayout.dragStripSize)
        XCTAssertLessThan(strip.width, page.width / 4, "a short strip")
        XCTAssertEqual(layout.windowDragStripFrame(isEnabled: false), .zero)
        // Hidden sidebar: still centered on the (wider) page.
        let hidden = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985), isSidebarVisible: false)
        XCTAssertEqual(hidden.windowDragStripFrame(isEnabled: true).midX, hidden.pageFrame.midX, accuracy: 0.01)
    }

    // MARK: [03 §Advanced] Export Data

    /// The export holds live profiles, favorites, pinned folders (nested), Today and the archive.
    func testWorkspaceExportContent() throws {
        let f = SidebarFixture()
        var ws = try TreeOps.archiveTab(f.ws, id: f.today1, reason: .closed, now: f.now)
        ws = try TreeOps.deleteFolder(ws, id: f.folderC, now: f.now)
        let export = WorkspaceExport.make(ws, exportedAt: clock)
        XCTAssertEqual(export.format, WorkspaceExport.formatName)
        XCTAssertEqual(export.formatVersion, 1)
        let profile = try XCTUnwrap(export.profiles.first)
        XCTAssertEqual(profile.name, "Default")
        XCTAssertEqual(profile.favorites.map(\.title), ["fav1.example.com", "fav2.example.com"])
        XCTAssertEqual(profile.spaces.map(\.name), ["Home", "Work"])
        let home = profile.spaces[0]
        XCTAssertEqual(home.pinned.map(\.title), ["A", "pinned.example.com"], "deleted folder C is not exported")
        let folderA = home.pinned[0]
        XCTAssertEqual(folderA.kind, "folder")
        XCTAssertEqual(folderA.items?.map(\.title), ["B", "infolder.example.com"])
        XCTAssertEqual(folderA.items?.first?.items?.map(\.url), ["https://deep.example.com"])
        XCTAssertEqual(home.today.map(\.title), ["today3", "today2"])
        XCTAssertEqual(export.archive.map(\.title), ["today1"])
        XCTAssertEqual(export.archive.first?.space, "Home")
        // Round trip through the file format.
        XCTAssertEqual(try WorkspaceExport.decode(export.encoded()), export)
    }

    /// Export Data asks where to save, then writes the JSON there; Cancel writes nothing.
    func testExportDataWritesChosenFile() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/b84-tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picker = CancelledExportPicker()
        let shell = makeShell(picker: picker)
        let settings = SettingsModel(shell: shell)

        let cancelled = await settings.exportData()
        XCTAssertNil(cancelled)
        XCTAssertNil(settings.exportStatus)
        XCTAssertEqual(picker.suggestedNames.first?.hasSuffix(".json"), true)
        XCTAssertEqual(picker.suggestedNames.first?.hasPrefix("Open Arc Export "), true)

        let target = directory.appendingPathComponent("export.json")
        picker.answer = target
        let written = await settings.exportData()
        XCTAssertEqual(written, target)
        let export = try WorkspaceExport.decode(Data(contentsOf: target))
        XCTAssertEqual(export.profiles.first?.spaces.first?.name, "Home")
        XCTAssertEqual(export.exportedAt, clock)
        XCTAssertEqual(settings.exportStatus, "Exported to export.json.")
        shell.stop()
    }

    func testExportFileNameUsesDate() {
        XCTAssertEqual(WorkspaceExport.suggestedFileName(at: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!),
                       "Open Arc Export 1970-01-01.json")
    }

    // MARK: [03 §Icon]

    /// Six icons; choosing one marks it CURRENT ICON, shows it in the Dock and stores it.
    func testIconChoiceSelectsShowsAndPersists() {
        XCTAssertEqual(AppIconChoice.allCases.count, 6)
        XCTAssertEqual(Set(AppIconChoice.allCases.map(\.displayName)).count, 6)
        let (preferences, _) = makePreferences()
        let display = RecordingAppIconDisplay()
        let icons = AppIconSettings(preferences: preferences, display: display)
        XCTAssertEqual(icons.current, .default)
        icons.select(.lagoon)
        XCTAssertEqual(icons.current, .lagoon)
        XCTAssertEqual(display.shown, [.lagoon])
        icons.select(.lagoon)
        XCTAssertEqual(display.shown, [.lagoon], "choosing the current icon again does nothing")
        XCTAssertEqual(preferences.appIconChoice, .lagoon)
    }

    /// The chosen icon survives a relaunch: a new controller shows the stored one at launch.
    func testIconChoiceSurvivesRelaunch() {
        let (preferences, _) = makePreferences()
        let first = RecordingAppIconDisplay()
        let shell = makeShell(preferences: preferences, icons: first)
        XCTAssertTrue(first.shown.isEmpty, "the default icon needs nothing at launch")
        SettingsModel(shell: shell).appIcon.select(.night)
        shell.stop()

        let second = RecordingAppIconDisplay()
        let relaunched = makeShell(preferences: preferences, icons: second)
        XCTAssertEqual(relaunched.controller.appIcon.current, .night)
        XCTAssertEqual(second.shown, [.night])
        relaunched.stop()
    }

    /// An unknown stored value (a newer build's icon) reads as the default.
    func testUnknownStoredIconReadsAsDefault() {
        let (preferences, _) = makePreferences()
        preferences.setString("future-icon", AppPreferences.appIconKey)
        XCTAssertEqual(preferences.appIconChoice, .default)
    }

    /// Every variant renders, and they look different (sampled at the body's top).
    func testIconVariantsRenderDistinctly() throws {
        var colors: [[UInt8]] = []
        for choice in AppIconChoice.allCases {
            let image = try XCTUnwrap(AppIconRenderer.cgImage(choice, pixels: 64), "\(choice)")
            XCTAssertEqual(image.width, 64)
            let rep = NSBitmapImageRep(cgImage: image)
            let color = try XCTUnwrap(rep.colorAt(x: 32, y: 10)?.usingColorSpace(.sRGB))
            colors.append([color.redComponent, color.greenComponent, color.blueComponent].map { UInt8($0 * 255) })
        }
        XCTAssertEqual(Set(colors).count, AppIconChoice.allCases.count)
    }
}
