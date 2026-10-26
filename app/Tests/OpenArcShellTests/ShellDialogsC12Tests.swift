import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan C12: shell-drawn dialogs and the Library's Downloads section. The dialogs are not in
/// docs/arc-spec (their look and wording are our own: unknown / inferred, Chromium's semantics);
/// Downloads: `06 §8` observed (search field "Search Downloads…", "Filter", empty state).
@MainActor
final class ShellDialogsC12Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func openPage(_ address: String) async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try url(address))
        let id = try XCTUnwrap(opened)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: Permission prompts (Chromium semantics, inferred)

    /// A prompt for kinds without a one-time grant (notifications) offers no "Allow This Time";
    /// its second button stores the grant.
    func testPermissionPromptWithoutOneTimeGrantHasTwoButtons() async throws {
        let live = try await openPage("https://notify.example")
        let center = model.controller.dialogs
        let id = live.simulatePermissionPrompt([.notifications], supportsAllowingOnce: false)
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).buttons, ["Don’t Allow", "Allow"])
        XCTAssertEqual(DialogPresentation(request).message, "Show notifications")
        center.answer(id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .permission(.allow(remember: true)))
    }

    func testPermissionPromptWithOneTimeGrantOffersAllowThisTime() async throws {
        let live = try await openPage("https://camera.example")
        let center = model.controller.dialogs
        let id = live.simulatePermissionPrompt([.camera])
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).buttons, ["Don’t Allow", "Allow This Time", "Allow"])
        center.answer(id, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .permission(.deny(remember: true)))
    }

    // MARK: External protocol (Chromium semantics, inferred)

    /// The "always allow" checkbox appears only when the engine may remember the choice (Chromium:
    /// a potentially trustworthy origin).
    func testExternalProtocolCheckboxFollowsTheEngine() async throws {
        let live = try await openPage("http://plain.example")
        let center = model.controller.dialogs
        let id = live.simulateExternalProtocol(try url("zoommtg://join"), handlerApplicationName: "Zoom", canRememberForOrigin: false)
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertNil(DialogPresentation(request).checkbox)
        XCTAssertEqual(DialogPresentation(request).buttons, ["Cancel", "Open"])
        center.answer(id, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .externalProtocol(.block))
    }

    // MARK: Downloads [06 §8]

    /// Library ▸ Downloads shows the profile's downloads live: added, updated, removed; the search
    /// field filters by file name or source.
    func testDownloadsSectionFollowsTheEngine() async throws {
        let downloads = try XCTUnwrap(engine.downloads as? FakeDownloads)
        let profileID = try XCTUnwrap(model.sidebar.currentProfileID)
        model.library.open(.downloads)
        let list = model.library.downloads
        XCTAssertTrue(list.items.isEmpty, "empty state first: [06 §8] Nothing here yet!")

        let report = DownloadItem(id: "a", profileID: profileID, sourceURL: try url("https://files.example/report.pdf"),
                                  suggestedFilename: "report.pdf", receivedBytes: 512, totalBytes: 1024,
                                  startDate: Date(timeIntervalSince1970: 10))
        let photo = DownloadItem(id: "b", profileID: profileID, sourceURL: try url("https://img.example/cat.png"),
                                 suggestedFilename: "cat.png", state: .complete, receivedBytes: 10, totalBytes: 10,
                                 startDate: Date(timeIntervalSince1970: 20))
        // Another profile's download is not listed.
        let other = DownloadItem(id: "c", profileID: UUID(), sourceURL: try url("https://x.example/x"),
                                 suggestedFilename: "x", startDate: Date(timeIntervalSince1970: 30))
        try await waitUntil { downloads.subscriberCount(profileID: profileID) > 0 }
        downloads.simulateDownload(report)
        downloads.simulateDownload(photo)
        downloads.simulateDownload(other)
        try await waitUntil { list.items.count == 2 }
        XCTAssertEqual(list.items.map(\.id), ["b", "a"], "newest first")
        XCTAssertEqual(list.filtered(by: "REPORT").map(\.id), ["a"])
        XCTAssertEqual(list.filtered(by: "img.example").map(\.id), ["b"])

        list.pause("a")
        try await waitUntil { list.items.first { $0.id == "a" }?.state == .paused }
        list.remove("b")
        try await waitUntil { list.items.map(\.id) == ["a"] }
        XCTAssertEqual(downloads.commands, ["pause:a", "remove:b"])
    }

    func testDownloadRowPresentation() throws {
        let profile = UUID()
        var item = DownloadItem(id: "a", profileID: profile, sourceURL: try url("https://files.example/r.pdf"),
                                suggestedFilename: "r.pdf", receivedBytes: 500, totalBytes: 1000,
                                startDate: Date(timeIntervalSince1970: 0))
        var row = DownloadRowPresentation(item)
        XCTAssertEqual(row.title, "r.pdf")
        XCTAssertEqual(row.progress, 0.5)
        XCTAssertEqual(row.actions, [.pause, .cancel])
        XCTAssertTrue(row.detail.hasSuffix("files.example"))

        item.state = .needsConfirmation
        item.warningText = "This type of file can harm your computer."
        row = DownloadRowPresentation(item)
        XCTAssertEqual(row.actions, [.discard, .keep])
        XCTAssertEqual(row.detail, "This type of file can harm your computer.")

        item.state = .complete
        XCTAssertEqual(DownloadRowPresentation(item).actions, [.reveal, .remove])
        item.state = .interrupted
        XCTAssertEqual(DownloadRowPresentation(item).actions, [.retry, .remove])
        item.totalBytes = -1
        item.state = .inProgress
        XCTAssertNil(DownloadRowPresentation(item).progress, "unknown size: no bar")
    }
}
