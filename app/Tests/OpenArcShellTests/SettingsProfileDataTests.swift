import XCTest
import AppKit
import SwiftUI
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Settings ▸ Profiles data rows (plan B83). Spec: docs/arc-spec/03-settings.md §Profiles
/// (observed: Manage search / Search Settings…, Download location default Downloads, "Your Data and
/// Settings" rows Privacy and Security · Passwords · Credit Cards · Notifications · Autofill ·
/// Clear Browsing Data, Learn more) and §Advanced (observed: More Settings…). Targets inferred.
@MainActor
final class SettingsProfileDataTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeShell(engine: FakeEngine = FakeEngine()) -> ShellModel {
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        var tick = clock
        // An advancing clock: "Default" stays the oldest profile.
        return ShellModel(dependencies: deps, workspace: .demo(now: clock), now: {
            tick = tick.addingTimeInterval(1)
            return tick
        })
    }

    /// Adds a profile with one Space and returns both ids.
    private func addProfileWithSpace(_ settings: SettingsModel, name: String) throws -> (profile: UUID, space: UUID) {
        let shell = settings.shell
        let profile = settings.addProfile()
        let space = UUID()
        shell.sidebar.replaceWorkspace(try TreeOps.createSpace(shell.workspace, id: space, profileID: profile, name: name, now: clock))
        return (profile, space)
    }

    // MARK: [03 §Profiles] catalog

    /// Every data row, Search Settings…, Download location, Learn more and More Settings… are live.
    func testProfileDataControlsAreLive() {
        for id in ["profiles.learnMore", "profiles.searchSettings", "profiles.downloadLocation",
                   "profiles.privacy", "profiles.passwords", "profiles.creditCards",
                   "profiles.notifications", "profiles.autofill", "profiles.clearBrowsingData",
                   "advanced.moreSettings"] {
            XCTAssertTrue(SettingsCatalog.control(id).isEnabled, id)
        }
        // [03 §Profiles] observed row order.
        XCTAssertEqual(ProfilesPane.dataRows.map { SettingsCatalog.control($0.controlID).label },
                       ["Privacy and Security", "Passwords", "Credit Cards", "Notifications", "Autofill"])
    }

    // MARK: [03 §Profiles] engine pages

    /// Each row opens the engine's page in a new tab of a Space that uses the edited profile, so the
    /// engine tab belongs to that profile.
    func testDataRowsOpenEnginePagesForTheEditedProfile() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let settings = SettingsModel(shell: shell)
        let (work, workSpace) = try addProfileWithSpace(settings, name: "Work")
        settings.selectedProfileID = work
        XCTAssertTrue(settings.canOpenEditedProfilePages)

        let expected: [ProfileEnginePage: String] = [
            .privacy: "chrome://settings/privacy",
            .passwords: "chrome://password-manager/passwords",
            .creditCards: "chrome://settings/payments",
            .notifications: "chrome://settings/content/notifications",
            .autofill: "chrome://settings/addresses",
            .searchSettings: "chrome://settings/searchEngines",
        ]
        for (page, url) in expected.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let id = try XCTUnwrap(settings.openEnginePage(page), "\(page)")
            let tab = try XCTUnwrap(shell.workspace.tabs[id])
            XCTAssertEqual(tab.url?.absoluteString, url, "\(page)")
            XCTAssertEqual(tab.location, .today(spaceID: workSpace), "\(page)")
            // The window shows it: switched to the Work Space and selected the new tab.
            XCTAssertEqual(shell.selectedSpaceID, workSpace)
            XCTAssertEqual(shell.selectedTabID, id)
            await shell.sidebar.settleEngineWork()
            let live = try XCTUnwrap(shell.sidebar.liveTab(for: id), "\(page)")
            XCTAssertEqual(live.profileID, work, "\(page)")
        }
        shell.stop()
    }

    /// A profile no Space uses has nowhere to open a page: the rows are disabled and do nothing.
    func testDataRowsNeedASpaceOfTheProfile() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        _ = settings.addProfile()
        let before = shell.workspace.tabs.count
        XCTAssertFalse(settings.canOpenEditedProfilePages)
        XCTAssertNil(settings.openEnginePage(.privacy))
        XCTAssertEqual(shell.workspace.tabs.count, before)
        shell.stop()
    }

    /// The active window's Space wins when it uses the profile; otherwise the profile's first Space.
    func testEnginePageSpacePrefersTheActiveWindowsSpace() throws {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        let defaultProfile = try XCTUnwrap(shell.workspace.defaultProfileID)
        let current = try XCTUnwrap(shell.selectedSpaceID)
        let second = UUID()
        shell.sidebar.replaceWorkspace(try TreeOps.createSpace(shell.workspace, id: second, profileID: defaultProfile, name: "Second", now: clock))
        shell.selectSpace(second)
        XCTAssertEqual(settings.space(forProfile: defaultProfile), second)
        shell.selectSpace(current)
        XCTAssertEqual(settings.space(forProfile: defaultProfile), current)
        shell.stop()
    }

    /// [03 §Advanced] More Settings…: the engine's settings for the current window's profile.
    func testMoreSettingsOpensEngineSettings() async throws {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        let id = try XCTUnwrap(settings.openMoreSettings())
        XCTAssertEqual(shell.workspace.tabs[id]?.url?.absoluteString, "chrome://settings/")
        XCTAssertEqual(shell.selectedTabID, id)
        await shell.sidebar.settleEngineWork()
        XCTAssertEqual(shell.sidebar.liveTab(for: id)?.profileID, shell.workspace.defaultProfileID)
        shell.stop()
    }

    /// [03 §Profiles] Learn more: our help page in a tab.
    func testLearnMoreOpensOurHelpPage() throws {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        let id = try XCTUnwrap(settings.openProfilesHelp())
        XCTAssertEqual(shell.workspace.tabs[id]?.url, ProfileHelpLinks.profiles)
        XCTAssertEqual(ProfileHelpLinks.profiles.host, "openarc.github.io")
        shell.stop()
    }

    // MARK: [03 §Profiles] Download location

    /// Default Downloads; a choice goes to the engine for the edited profile only, and reads back.
    func testDownloadLocationIsPerProfile() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let settings = SettingsModel(shell: shell)
        let defaultProfile = try XCTUnwrap(settings.editedProfileID)
        await settings.loadDownloadDirectory()
        XCTAssertEqual(settings.downloadDirectory, SettingsModel.userDownloadsFolder)
        XCTAssertEqual(SettingsCatalog.control("profiles.downloadLocation").kind, .picker(defaultValue: "Downloads"))
        XCTAssertEqual(settings.downloadLocationChoices, [.folder(SettingsModel.userDownloadsFolder.standardizedFileURL), .other])

        let folder = URL(fileURLWithPath: "/tmp/openarc-b83-downloads", isDirectory: true)
        await settings.chooseDownloadLocation(.folder(folder))
        XCTAssertEqual(engine.fakeDownloadService.defaultDirectories, [defaultProfile: folder])
        XCTAssertEqual(settings.downloadDirectory, folder)
        // Downloads stays offered next to the chosen folder.
        XCTAssertEqual(settings.downloadLocationChoices,
                       [.folder(folder.standardizedFileURL), .folder(SettingsModel.userDownloadsFolder.standardizedFileURL), .other])

        // Another profile keeps Downloads.
        let work = settings.addProfile()
        await settings.loadDownloadDirectory()
        XCTAssertEqual(settings.editedProfileID, work)
        XCTAssertEqual(settings.downloadDirectory, SettingsModel.userDownloadsFolder)

        // A fresh Settings window reads the folder back from the engine.
        let reopened = SettingsModel(shell: shell)
        reopened.selectedProfileID = defaultProfile
        await reopened.loadDownloadDirectory()
        XCTAssertEqual(reopened.downloadDirectory, folder)
        shell.stop()
    }

    /// "Other…" asks for a folder; cancelling changes nothing.
    func testDownloadLocationOtherAsksForAFolder() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let settings = SettingsModel(shell: shell)
        let profile = try XCTUnwrap(settings.editedProfileID)
        var asked: URL?
        settings.pickFolder = { asked = $0; return nil }
        await settings.chooseDownloadLocation(.other)
        XCTAssertEqual(asked, SettingsModel.userDownloadsFolder)
        XCTAssertTrue(engine.fakeDownloadService.defaultDirectories.isEmpty)

        let picked = URL(fileURLWithPath: "/tmp/openarc-b83-picked", isDirectory: true)
        settings.pickFolder = { _ in picked }
        await settings.chooseDownloadLocation(.other)
        XCTAssertEqual(engine.fakeDownloadService.defaultDirectories[profile], picked)
        shell.stop()
    }

    // MARK: [03 §Profiles] Clear Browsing Data

    /// The sheet clears the chosen kinds of the edited profile from the start of the time range.
    func testClearBrowsingDataSheet() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let settings = SettingsModel(shell: shell)
        let (work, _) = try addProfileWithSpace(settings, name: "Work")
        settings.selectedProfileID = work

        settings.requestClearBrowsingData()
        XCTAssertEqual(settings.profileClearingData, work)
        XCTAssertEqual(settings.profileClearingDataName, shell.workspace.profiles[work]?.name)
        // Nothing checked: nothing happens and the sheet stays.
        let refused = await settings.confirmClearBrowsingData(range: .allTime, kinds: [])
        XCTAssertFalse(refused)
        XCTAssertTrue(engine.clearedBrowsingData.isEmpty)
        XCTAssertEqual(settings.profileClearingData, work)

        // Default selection, last hour.
        let cleared = await settings.confirmClearBrowsingData(range: .lastHour, kinds: ClearBrowsingDataKind.defaultSelection)
        XCTAssertTrue(cleared)
        XCTAssertNil(settings.profileClearingData)
        let first = try XCTUnwrap(engine.clearedBrowsingData.first)
        XCTAssertEqual(first.profileID, work)
        XCTAssertEqual(first.types, [.history, .cookies, .siteStorage, .cache])
        let since = try XCTUnwrap(first.since)
        XCTAssertEqual(since.timeIntervalSince(shell.controller.now()), -3600, accuracy: 5)

        // All time, every kind.
        settings.requestClearBrowsingData()
        await settings.confirmClearBrowsingData(range: .allTime, kinds: Set(ClearBrowsingDataKind.allCases))
        let second = try XCTUnwrap(engine.clearedBrowsingData.last)
        XCTAssertNil(second.since)
        XCTAssertEqual(second.types, .all)
        shell.stop()
    }

    /// Cancel closes the sheet without clearing.
    func testCancelClearBrowsingData() {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let settings = SettingsModel(shell: shell)
        settings.requestClearBrowsingData()
        XCTAssertNotNil(settings.profileClearingData)
        settings.cancelClearBrowsingData()
        XCTAssertNil(settings.profileClearingData)
        XCTAssertTrue(engine.clearedBrowsingData.isEmpty)
        shell.stop()
    }

    /// Time ranges and kinds map onto the engine's values.
    func testClearBrowsingDataRangesAndKinds() {
        let now = clock
        XCTAssertEqual(ClearBrowsingDataRange.allCases.map(\.displayName),
                       ["Last hour", "Last 24 hours", "Last 7 days", "Last 4 weeks", "All time"])
        XCTAssertEqual(ClearBrowsingDataRange.last24Hours.since(now: now), now.addingTimeInterval(-86_400))
        XCTAssertEqual(ClearBrowsingDataRange.last4Weeks.since(now: now), now.addingTimeInterval(-28 * 86_400))
        XCTAssertNil(ClearBrowsingDataRange.allTime.since(now: now))
        XCTAssertEqual(ClearBrowsingDataKind.types(of: [.passwords, .autofill, .siteSettings, .downloads]),
                       [.passwords, .autofill, .siteSettings, .downloads])
        XCTAssertEqual(ClearBrowsingDataKind.types(of: Set(ClearBrowsingDataKind.allCases)), .all)
    }

    // MARK: Rendering

    /// The pane with a Profile no Space uses, and the sheet, lay out.
    func testProfilesPaneAndSheetLayOut() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        _ = settings.addProfile()
        settings.requestClearBrowsingData()
        for view in [AnyView(ProfilesPane(model: settings)), AnyView(ClearBrowsingDataSheet(model: settings))] {
            let host = NSHostingView(rootView: view.frame(width: SettingsTokens.windowWidth))
            host.frame = CGRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 560)
            host.layoutSubtreeIfNeeded()
        }
        shell.stop()
    }
}
