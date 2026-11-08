import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Usage analytics (plan B194, docs posthog-integration.md): on by default, nothing before the
/// notice, four allowlisted events within daily limits, nothing from incognito windows, and off
/// stops collection and drops everything pending.
@MainActor
final class UsageAnalyticsTests: XCTestCase {
    private let config = UsageAnalyticsConfiguration(
        apiKey: "phc_test", endpoint: URL(string: "https://capture.example/batch/")!,
        appVersion: "0.2.6", osMajor: "26", architecture: "arm64"
    )
    private var clock = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15, 08:00 UTC
    private var ids = 0

    private func makeAnalytics(
        preferences: AppPreferences = .inMemory(), configuration: UsageAnalyticsConfiguration? = nil,
        transport: RecordingUsageAnalyticsTransport = RecordingUsageAnalyticsTransport()
    ) -> UsageAnalytics {
        UsageAnalytics(
            preferences: preferences, configuration: configuration ?? config, transport: transport,
            now: { [unowned self] in self.clock },
            makeID: { [unowned self] in self.ids += 1; return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", self.ids))! },
            flushDelay: 3600
        )
    }

    private func batch(_ body: Data) throws -> (apiKey: String, events: [[String: Any]]) {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (try XCTUnwrap(json["api_key"] as? String), try XCTUnwrap(json["batch"] as? [[String: Any]]))
    }

    // MARK: Choice and notice

    func testOnByDefaultButNothingBeforeTheNotice() async {
        let transport = RecordingUsageAnalyticsTransport()
        let analytics = makeAnalytics(transport: transport)
        XCTAssertEqual(analytics.preference, .defaultEnabled)
        XCTAssertTrue(analytics.isSharingEnabled)
        XCTAssertTrue(analytics.needsNotice)
        XCTAssertFalse(analytics.isCollecting)
        XCTAssertFalse(analytics.record(.activeDay))
        await analytics.flush()
        XCTAssertTrue(transport.sent.isEmpty)

        analytics.noticeDidAppear()
        XCTAssertTrue(analytics.isNoticeOnScreen)
        XCTAssertFalse(analytics.needsNotice, "shown once")
        XCTAssertTrue(analytics.isCollecting)
        XCTAssertTrue(analytics.record(.activeDay))
        analytics.dismissNotice()
        XCTAssertFalse(analytics.isNoticeOnScreen)
        XCTAssertTrue(analytics.isCollecting, "Dismiss keeps the setting")
    }

    func testDevelopmentBuildsNeverCollectOrAsk() {
        let analytics = UsageAnalytics(preferences: .inMemory(), configuration: nil, transport: RecordingUsageAnalyticsTransport())
        analytics.markNoticePresented()
        XCTAssertFalse(analytics.isAvailable)
        XCTAssertFalse(analytics.needsNotice)
        XCTAssertFalse(analytics.isCollecting)
        XCTAssertFalse(analytics.record(.activeDay))
    }

    func testUnknownStoredPreferenceFailsClosed() {
        let suite = "openarc.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("someFutureValue", forKey: AppPreferences.usageAnalyticsPreferenceKey)
        let analytics = makeAnalytics(preferences: AppPreferences(defaults: defaults))
        XCTAssertEqual(analytics.preference, .disabled)
        XCTAssertFalse(analytics.needsNotice)
    }

    func testAnExplicitOffSurvivesAndIsNeverAskedAgain() {
        let preferences = AppPreferences.inMemory()
        makeAnalytics(preferences: preferences).setSharingEnabled(false)
        let relaunched = makeAnalytics(preferences: preferences)
        XCTAssertEqual(relaunched.preference, .disabled)
        XCTAssertFalse(relaunched.needsNotice)
        relaunched.markNoticePresented()
        XCTAssertFalse(relaunched.isCollecting)
    }

    // MARK: Limits

    func testDailyLimits() {
        let analytics = makeAnalytics()
        analytics.markNoticePresented()
        XCTAssertTrue(analytics.record(.activeDay))
        XCTAssertFalse(analytics.record(.activeDay), "once per UTC day")
        XCTAssertTrue(analytics.record(.featureUsed(.peek)))
        XCTAssertFalse(analytics.record(.featureUsed(.peek)))
        XCTAssertTrue(analytics.record(.featureUsed(.spaces)))
        for _ in 0..<3 { XCTAssertTrue(analytics.record(.archiveIntervalChanged(.hours24))) }
        XCTAssertFalse(analytics.record(.archiveIntervalChanged(.days7)), "at most 3 a day")

        clock = clock.addingTimeInterval(24 * 3600)
        XCTAssertTrue(analytics.record(.activeDay), "a new UTC day")
        XCTAssertTrue(analytics.record(.featureUsed(.peek)))
    }

    func testGlobalCapOfTwentyADay() {
        let analytics = makeAnalytics()
        analytics.markNoticePresented()
        var accepted = 0
        // Each feature once, plus repeated imports and interval changes, over many "days" of
        // keys; the cap holds within one day.
        for _ in 0..<5 {
            for event in [UsageEvent.activeDay, .arcImportFinished(.success), .archiveIntervalChanged(.days30)]
                + UsageFeature.allCases.map(UsageEvent.featureUsed) where analytics.record(event) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 1 + 3 + 3 + UsageFeature.allCases.count, "per-event limits first")
        XCTAssertLessThanOrEqual(accepted, UsageAnalytics.dailyEventCap)
        XCTAssertLessThanOrEqual(analytics.queue.count, UsageAnalytics.dailyEventCap)
    }

    func testIncognitoActionsAreNeverRecorded() {
        let analytics = makeAnalytics()
        analytics.markNoticePresented()
        XCTAssertFalse(analytics.record(.activeDay, isPrivate: true))
        XCTAssertTrue(analytics.queue.isEmpty)
    }

    // MARK: Payload

    func testPayloadCarriesOnlyAllowlistedFields() async throws {
        let transport = RecordingUsageAnalyticsTransport()
        let analytics = makeAnalytics(transport: transport)
        analytics.markNoticePresented()
        analytics.record(.featureUsed(.splitView))
        analytics.record(.arcImportFinished(.partial))
        await analytics.flush()
        let sent = try batch(XCTUnwrap(transport.sent.first))
        XCTAssertEqual(sent.apiKey, "phc_test")
        XCTAssertEqual(sent.events.map { $0["event"] as? String }, ["feature_used", "arc_import_finished"])
        let allowed: Set<String> = [
            "distinct_id", "$process_person_profile", "$geoip_disable", "$lib", "schema_version", "app_version",
            "os_major", "architecture", "environment", "surface", "feature", "result", "interval",
        ]
        for event in sent.events {
            XCTAssertEqual(Set(event.keys), ["event", "properties", "timestamp"])
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            XCTAssertTrue(Set(properties.keys).isSubset(of: allowed), "\(properties.keys)")
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
            XCTAssertEqual(properties["surface"] as? String, "macos")
            XCTAssertEqual(properties["app_version"] as? String, "0.2.6")
            XCTAssertEqual(properties["distinct_id"] as? String, "00000000-0000-0000-0000-000000000001")
        }
        let first = try XCTUnwrap(sent.events.first?["properties"] as? [String: Any])
        XCTAssertEqual(first["feature"] as? String, "split_view")
        XCTAssertTrue(analytics.queue.isEmpty)
    }

    func testFailedSendKeepsTheEventsForTheNextAttempt() async throws {
        let transport = RecordingUsageAnalyticsTransport()
        let analytics = makeAnalytics(transport: transport)
        analytics.markNoticePresented()
        analytics.record(.activeDay)
        transport.fail(with: URLError(.notConnectedToInternet))
        await analytics.flush()
        XCTAssertEqual(analytics.queue.count, 1)
        transport.fail(with: nil)
        await analytics.flush()
        XCTAssertTrue(analytics.queue.isEmpty)
        XCTAssertEqual(try batch(XCTUnwrap(transport.sent.first)).events.count, 1)
        analytics.stop()
    }

    // MARK: Turning off

    func testTurningOffDropsEverythingPendingAndTheIdentity() async {
        let preferences = AppPreferences.inMemory()
        let transport = RecordingUsageAnalyticsTransport()
        let analytics = makeAnalytics(preferences: preferences, transport: transport)
        analytics.markNoticePresented()
        analytics.record(.activeDay)
        XCTAssertNotNil(preferences.usageAnalyticsInstallID)

        analytics.setSharingEnabled(false)
        XCTAssertEqual(preferences.usageAnalyticsPreference, .disabled)
        XCTAssertTrue(analytics.queue.isEmpty)
        XCTAssertNil(preferences.usageAnalyticsInstallID)
        XCTAssertFalse(analytics.record(.featureUsed(.peek)))
        await analytics.flush()
        XCTAssertTrue(transport.sent.isEmpty, "nothing is ever sent")

        analytics.setSharingEnabled(true)
        XCTAssertEqual(analytics.preference, .explicitlyEnabled)
        XCTAssertTrue(analytics.record(.featureUsed(.peek)))
        XCTAssertEqual(preferences.usageAnalyticsInstallID, "00000000-0000-0000-0000-000000000002", "a new identity")
        analytics.stop()
    }

    // MARK: The app

    private func makeShell(workspace: WorkspaceState? = nil) -> ShellModel {
        let deps = AppDependencies(
            engine: FakeEngine(), sync: DisabledSyncStore(), preferences: .inMemory(),
            usageAnalyticsConfiguration: config, usageAnalyticsTransport: RecordingUsageAnalyticsTransport()
        )
        return ShellModel(dependencies: deps, workspace: workspace ?? .demo(now: clock), now: { [unowned self] in self.clock })
    }

    private func events(_ analytics: UsageAnalytics) -> [String] {
        analytics.queue.map { event in
            let properties = event["properties"] as? [String: Any] ?? [:]
            return [event["event"] as? String, properties["feature"] as? String].compactMap { $0 }.joined(separator: ":")
        }
    }

    func testAppActionsRecordTheirFeatureOnlyOnceTheNoticeWasShown() async {
        let fixture = SidebarFixture()
        clock = fixture.now
        let shell = makeShell(workspace: fixture.ws)
        let analytics = shell.controller.usageAnalytics
        shell.selectSpace(fixture.work)
        XCTAssertTrue(analytics.queue.isEmpty, "no notice yet")
        analytics.markNoticePresented()
        shell.selectSpace(fixture.home)
        shell.sidebar.selectTab(fixture.today1)
        shell.sidebar.addSplitView()
        XCTAssertEqual(events(analytics), ["feature_used:spaces", "app_active_day", "feature_used:split_view"])
        shell.stop()
    }

    func testArchiveIntervalChangeIsRecorded() throws {
        let shell = makeShell()
        let analytics = shell.controller.usageAnalytics
        analytics.markNoticePresented()
        let settings = SettingsModel(shell: shell)
        settings.archiveLifetime = .sevenDays
        settings.archiveLifetime = .sevenDays // unchanged: not recorded
        let properties = try XCTUnwrap(analytics.queue.first?["properties"] as? [String: Any])
        XCTAssertEqual(analytics.queue.count, 1)
        XCTAssertEqual(properties["interval"] as? String, "7d")
        shell.stop()
    }

    func testSettingsSwitchAndReviewRequest() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        settings.selectedPane = .links
        shell.controller.requestUsageDataSettings()
        XCTAssertEqual(settings.selectedPane, .general)
        settings.usageAnalytics.setSharingEnabled(false)
        XCTAssertFalse(settings.usageAnalytics.isSharingEnabled)
        shell.stop()
    }

    func testOnboardingCardSavesTheChoiceOnStartBrowsing() {
        let shell = makeShell()
        let analytics = shell.controller.usageAnalytics
        let onboarding = shell.controller.onboarding
        onboarding.showAgain(in: shell)
        while onboarding.step != .done { onboarding.next() }
        XCTAssertTrue(onboarding.showsUsageDataCard)
        XCTAssertTrue(onboarding.shareUsageDataDraft)
        XCTAssertFalse(analytics.hasPresentedNotice, "the draft is saved by Start Browsing")
        onboarding.shareUsageDataDraft = false
        onboarding.next()
        XCTAssertTrue(analytics.hasPresentedNotice)
        XCTAssertEqual(analytics.preference, .disabled)
        shell.stop()
    }

    func testOnboardingDefaultStaysDefaultAndSkippingDoesNotCountAsTheNotice() {
        let shell = makeShell()
        let analytics = shell.controller.usageAnalytics
        let onboarding = shell.controller.onboarding
        onboarding.showAgain(in: shell)
        onboarding.next()
        onboarding.skip()
        XCTAssertFalse(analytics.hasPresentedNotice, "skipped before the last page")
        XCTAssertTrue(analytics.needsNotice, "the window notice comes next")

        onboarding.showAgain(in: shell)
        while onboarding.step != .done { onboarding.next() }
        onboarding.next()
        XCTAssertEqual(analytics.preference, .defaultEnabled)
        XCTAssertTrue(analytics.isCollecting)
        shell.stop()
    }

    func testIncognitoWindowRecordsNothing() {
        let shell = makeShell()
        shell.controller.usageAnalytics.markNoticePresented()
        let incognito = shell.controller.makeIncognito()
        XCTAssertTrue(incognito.usageAnalytics === shell.controller.usageAnalytics)
        incognito.recordUsage(.featureUsed(.peek))
        XCTAssertTrue(shell.controller.usageAnalytics.queue.isEmpty)
        incognito.stop()
        shell.stop()
    }

    func testImportResultMapping() {
        let ok = ImportSummaryLine(text: "ok", isError: false), bad = ImportSummaryLine(text: "bad", isError: true)
        XCTAssertEqual(BookmarkImportModel.usageResult([ok, ok]), .success)
        XCTAssertEqual(BookmarkImportModel.usageResult([ok, bad]), .partial)
        XCTAssertEqual(BookmarkImportModel.usageResult([bad]), .failed)
        XCTAssertEqual(BookmarkImportModel.usageResult([]), .failed)
        XCTAssertEqual(UsageArchiveInterval(seconds: 12 * 3600), .hours12)
        XCTAssertEqual(UsageArchiveInterval(seconds: 5), .custom)
    }

    func testLiveConfigurationOnlyForTheReleaseBundle() {
        // The test runner is not the release app bundle.
        XCTAssertNil(UsageAnalyticsConfiguration.live())
        XCTAssertNil(UsageAnalyticsConfiguration.developmentPreview())
    }
}
