import XCTest
import OpenArcModel
import OpenArcEngine

/// Conformance tests for the engine protocol additions of plan C7b
/// (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §1–§10), run against FakeEngine.
final class EngineProtocolTests: XCTestCase {
    private let profile = UUID()

    private func take<S: AsyncSequence>(_ count: Int, from stream: S) async rethrows -> [S.Element] {
        var result: [S.Element] = []
        guard count > 0 else { return result }
        for try await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func makeTab(_ engine: FakeEngine, _ address: String? = "https://page.example/a") async throws -> FakeTab {
        let initial = try address.map(url)
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: initial))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// Waits until the fake recorded an answer for `id` (default answers come from `deinit`).
    private func answer(_ tab: FakeTab, _ id: UUID) async -> FakeDialogAnswer? {
        for _ in 0..<200 {
            if let answer = tab.dialogAnswers[id] { return answer }
            await Task.yield()
        }
        return tab.dialogAnswers[id]
    }

    // MARK: §1 Engine-created tabs

    func testWindowOpenHandsOverAPendingTabThatCanBeAdopted() async throws {
        let engine = FakeEngine()
        let opener = try await makeTab(engine)
        let events = engine.events()
        let popupURL = try url("https://auth.example/login")
        let token = try XCTUnwrap(engine.simulateWindowOpen(from: opener.id, url: popupURL, disposition: .popup))

        let received = await take(1, from: events)
        guard case .newTabRequested(let request)? = received.first else { return XCTFail("expected a new tab request") }
        XCTAssertEqual(request.pendingTab, token)
        XCTAssertEqual(request.opener, opener.id)
        XCTAssertEqual(request.disposition, .popup)
        XCTAssertEqual(engine.pendingTabTokens, [token])

        let id = EngineTabID(UUID())
        let adopted = try await engine.adoptTab(token, requestedID: id)
        XCTAssertEqual(adopted.id, id)
        XCTAssertEqual(adopted.profileID, profile, "the opener's profile")
        XCTAssertEqual((adopted as? FakeTab)?.opener, opener.id, "window.opener survives adoption")
        let adoptedURL = await adopted.currentState().url
        XCTAssertEqual(adoptedURL, popupURL)
        XCTAssertTrue(engine.pendingTabTokens.isEmpty)

        // A token answers once.
        do {
            _ = try await engine.adoptTab(token, requestedID: nil)
            XCTFail("expected requestFinished")
        } catch {
            XCTAssertEqual(error as? EngineError, .requestFinished)
        }
    }

    func testDeclinedOrOrphanedPendingTabsCannotBeAdopted() async throws {
        let engine = FakeEngine()
        let opener = try await makeTab(engine)
        let declined = try XCTUnwrap(engine.simulateWindowOpen(from: opener.id, url: try url("https://a.example")))
        await engine.declineTab(declined)
        await engine.declineTab(declined)   // idempotent
        let orphaned = try XCTUnwrap(engine.simulateWindowOpen(from: opener.id, url: try url("https://b.example")))
        await engine.closeTab(opener.id)    // bridge: declined when the opener closes
        XCTAssertTrue(engine.pendingTabTokens.isEmpty)
        for token in [declined, orphaned] {
            do {
                _ = try await engine.adoptTab(token, requestedID: nil)
                XCTFail("expected requestFinished")
            } catch {
                XCTAssertEqual(error as? EngineError, .requestFinished)
            }
        }
        XCTAssertNil(engine.simulateWindowOpen(from: opener.id, url: try url("https://c.example")), "closed opener")
    }

    func testPlainURLRequestsCarryNoPendingTab() {
        let request = NewTabRequest(opener: nil, url: URL(fileURLWithPath: "/"), disposition: .backgroundTab, hasUserGesture: true)
        XCTAssertNil(request.pendingTab)
    }

    // MARK: §2 Close requests

    func testWindowCloseIsAReportNotAClose() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        tab.simulateWindowClose()
        let received = await take(2, from: events)
        XCTAssertEqual(received.last, .closeRequested)
        XCTAssertEqual(engine.tabIDs, [tab.id], "the shell closes it")
    }

    func testRequestCloseWithoutBeforeUnloadAgreesAtOnce() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        await tab.requestClose()
        let received = await take(2, from: events)
        XCTAssertEqual(received.last, .closeRequested)
        XCTAssertEqual(tab.commands, [.requestClose])
    }

    func testRequestCloseWithBeforeUnloadAsksFirst() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        tab.simulateBeforeUnloadHandler()
        let dialogs = tab.dialogRequests()
        let events = tab.events()
        await tab.requestClose()
        let request = try await XCTUnwrapAsync(await take(1, from: dialogs).first)
        guard case .javaScript(let dialog) = request else { return XCTFail("expected beforeunload") }
        XCTAssertEqual(dialog.kind, .beforeUnload)
        XCTAssertTrue(dialog.reply.send(JavaScriptDialogReply(accepted: true)))
        let received = await take(2, from: events)
        XCTAssertEqual(received.last, .closeRequested)
    }

    // MARK: §3 Dialog requests

    func testEveryDialogKindReachesTheSubscriberAndItsAnswerTheEngine() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let alert = tab.simulateJavaScriptDialog(.prompt, message: "Name?", defaultPromptText: "x")
        let auth = tab.simulateAuthentication(realm: "Staff")
        let permission = tab.simulatePermissionPrompt([.camera, .microphone])
        let chooser = tab.simulateFileChooser(.openMultiple, acceptedTypeIdentifiers: ["public.image"])
        let external = tab.simulateExternalProtocol(try url("mailto:a@b.example"), handlerApplicationName: "Mail")
        XCTAssertEqual(tab.outstandingDialogIDs, [alert, auth, permission, chooser, external])

        let requests = await take(5, from: stream)
        XCTAssertEqual(requests.map(\.id), [alert, auth, permission, chooser, external])
        XCTAssertEqual(requests.first?.origin, SiteOrigin(scheme: "https", host: "page.example"))
        let file = try url("file:///tmp/a.png")
        for request in requests {
            switch request {
            case .javaScript(let r):
                XCTAssertEqual(r.defaultPromptText, "x")
                r.reply.send(JavaScriptDialogReply(accepted: true, promptText: "Ada"))
            case .authentication(let r):
                XCTAssertEqual(r.realm, "Staff")
                r.reply.send(.proceed(username: "u", password: "p"))
            case .permission(let r):
                XCTAssertEqual(r.kinds, [.camera, .microphone])
                r.reply.send(.allow(remember: true))
            case .fileChooser(let r):
                XCTAssertEqual(r.mode, .openMultiple)
                r.reply.send(.select([file]))
            case .externalProtocol(let r):
                XCTAssertEqual(r.handlerApplicationName, "Mail")
                r.reply.send(.open(rememberForOrigin: false))
            }
            XCTAssertTrue(request.isFinished)
            XCTAssertFalse(request.answerWithDefault(), "single-shot")
        }
        XCTAssertEqual(tab.dialogAnswers[alert], .javaScript(JavaScriptDialogReply(accepted: true, promptText: "Ada")))
        XCTAssertEqual(tab.dialogAnswers[auth], .authentication(.proceed(username: "u", password: "p")))
        XCTAssertEqual(tab.dialogAnswers[permission], .permission(.allow(remember: true)))
        XCTAssertEqual(tab.dialogAnswers[chooser], .fileChooser(.select([file])))
        XCTAssertEqual(tab.dialogAnswers[external], .externalProtocol(.open(rememberForOrigin: false)))
        XCTAssertTrue(tab.outstandingDialogIDs.isEmpty)
    }

    /// Bridge rule (OACDialogDelegate.h): a request nobody answers gets its default.
    func testDroppedRequestsGetTheirDefaults() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        // No subscriber: each request is released at once.
        let alert = tab.simulateJavaScriptDialog(.confirm, message: "Sure?")
        let auth = tab.simulateAuthentication(realm: "r")
        let permission = tab.simulatePermissionPrompt([.location])
        let chooser = tab.simulateFileChooser(.open)
        let external = tab.simulateExternalProtocol(try url("zoommtg://x"), handlerApplicationName: nil)
        let answeredAlert = await answer(tab, alert)
        XCTAssertEqual(answeredAlert, .javaScript(.dismissed))
        let answeredAuth = await answer(tab, auth)
        XCTAssertEqual(answeredAuth, .authentication(.cancel))
        let answeredPermission = await answer(tab, permission)
        XCTAssertEqual(answeredPermission, .permission(.dismiss))
        let answeredChooser = await answer(tab, chooser)
        XCTAssertEqual(answeredChooser, .fileChooser(.cancel))
        let answeredExternal = await answer(tab, external)
        XCTAssertEqual(answeredExternal, .externalProtocol(.block))
    }

    func testSubscriberDroppingARequestAnswersTheDefault() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulatePermissionPrompt([.notifications])
        do {
            let request = await take(1, from: stream)
            XCTAssertEqual(request.first?.id, id)
        }
        let answered = await answer(tab, id)
        XCTAssertEqual(answered, .permission(.dismiss))
    }

    func testEngineCanWithdrawARequest() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let dialogs = tab.dialogRequests()
        let events = tab.events()
        let id = tab.simulateJavaScriptDialog(.alert, message: "Hi")
        let request = try await XCTUnwrapAsync(await take(1, from: dialogs).first)
        tab.simulateDialogCancel(id)
        let received = await take(2, from: events)
        XCTAssertEqual(received.last, .dialogCancelled(id))
        XCTAssertTrue(request.isFinished)
        XCTAssertFalse(request.answerWithDefault(), "a withdrawn request ignores answers")
        XCTAssertNil(tab.dialogAnswers[id])
    }

    func testDialogStreamFinishesWithTheTab() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        tab.simulateJavaScriptDialog(.alert, message: "1")
        await engine.closeTab(tab.id)
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(tab.outstandingDialogIDs.isEmpty)
    }

    // MARK: §4 Page commands

    /// [01 §View] observed Force Refresh the Page.
    func testReloadBypassingCache() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        try await tab.reload()
        try await tab.reload(bypassingCache: true)
        XCTAssertEqual(tab.commands, [.reload(bypassingCache: false), .reload(bypassingCache: true)])
    }

    /// [01 §View] observed Zoom In / Zoom Out / Zoom to Actual Size.
    func testZoomStepsThroughPresetsAndIsKeptPerSite() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let sameSite = try await makeTab(engine, "https://page.example/b")
        let otherSite = try await makeTab(engine, "https://other.example")
        await tab.zoomIn()
        var state = await tab.currentState()
        XCTAssertEqual(state.zoomFactor, 1.1)
        let followed = await sameSite.currentState().zoomFactor
        XCTAssertEqual(followed, 1.1, "per-site zoom (engine side)")
        let untouched = await otherSite.currentState().zoomFactor
        XCTAssertEqual(untouched, 1)
        await tab.zoomOut()
        await tab.zoomOut()
        state = await tab.currentState()
        XCTAssertEqual(state.zoomFactor, 0.9)
        await tab.resetZoom()
        state = await tab.currentState()
        XCTAssertEqual(state.zoomFactor, 1)
        try await tab.setZoom(2)
        // A new page of the same site picks the stored level up.
        let later = try await makeTab(engine, "https://page.example/c")
        let laterZoom = await later.currentState().zoomFactor
        XCTAssertEqual(laterZoom, 2)
        do {
            try await tab.setZoom(9)
            XCTFail("expected invalidArgument")
        } catch {
            XCTAssertEqual(error as? EngineError, .invalidArgument)
        }
        XCTAssertEqual(ZoomLevels.next(after: 5), 5)
        XCTAssertEqual(ZoomLevels.next(before: 0.25), 0.25)
    }

    func testZoomChangesAreEvents() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        await tab.zoomIn()
        let received = await take(2, from: events)
        XCTAssertEqual(received.last, .zoomChanged(1.1))
    }

    /// [01 §Edit] observed Find ▸ items.
    func testFindInPageReportsResults() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        tab.simulatePageText("one two One three one")
        let events = tab.events()
        await tab.find("one", options: FindOptions())
        await tab.find("one", options: FindOptions(findNext: true))
        await tab.find("one", options: FindOptions(backwards: true, findNext: true))
        await tab.find("One", options: FindOptions(matchCase: true))
        let received = await take(5, from: events)
        XCTAssertEqual(Array(received.dropFirst()), [
            .findResultChanged(FindResult(matches: 3, activeOrdinal: 1, isFinal: true)),
            .findResultChanged(FindResult(matches: 3, activeOrdinal: 2, isFinal: true)),
            .findResultChanged(FindResult(matches: 3, activeOrdinal: 1, isFinal: true)),
            .findResultChanged(FindResult(matches: 1, activeOrdinal: 1, isFinal: true)),
        ])
        await tab.stopFinding(keepSelection: true)
        tab.simulateSelection("two")
        let selected = await tab.selectedText()
        XCTAssertEqual(selected, "two")
        XCTAssertEqual(tab.commands.last, .stopFinding(keepSelection: true))
    }

    func testEditPrintSaveAndDevToolsAreForwarded() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        for command in EditCommand.allCases { await tab.perform(command) }
        await tab.print()
        let file = try url("file:///tmp/page.webarchive")
        try await tab.savePage(to: file)
        try await tab.savePage(to: file, format: .singleFile)
        await tab.showDevTools(.console)
        await tab.showDevTools(nil)
        XCTAssertEqual(tab.commands, EditCommand.allCases.map(FakeTabCommand.edit) + [
            .print, .savePage(file, .complete), .savePage(file, .singleFile), .showDevTools(.console), .showDevTools(nil),
        ])
    }

    /// Save Page As takes a file URL and one of three formats ([01 §File] observed item; formats
    /// inferred from Chromium). C15.
    func testSavePageNeedsAFileURL() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        do {
            try await tab.savePage(to: try url("https://elsewhere.example/page.html"), format: .htmlOnly)
            XCTFail("a web URL is not a save location")
        } catch let error as EngineError {
            XCTAssertEqual(error, .invalidArgument)
        }
        XCTAssertEqual(SavePageFormat.allCases.map(\.rawValue), [0, 1, 2], "raw values match OACSavePageFormat")
        XCTAssertEqual(SavePageFormat.singleFile.fileExtension, "mhtml")
        XCTAssertEqual(SavePageFormat.complete.fileExtension, "html")
    }

    /// Picture in Picture ([03 §Advanced] observed "Enable Picture in Picture when you leave a video
    /// tab", [06 §12] observed "Automatic Picture-In-Picture", default Allowed). C15: automatic
    /// entry needs a playing video on a site that allows it; manual entry needs a video.
    func testPictureInPictureRules() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        var entered = await tab.enterPictureInPicture(automatically: false)
        XCTAssertFalse(entered, "no video on the page")

        tab.simulateVideo(playing: false)
        entered = await tab.enterPictureInPicture(automatically: true)
        XCTAssertFalse(entered, "a paused video does not follow the user out of the tab")
        entered = await tab.enterPictureInPicture(automatically: false)
        XCTAssertTrue(entered, "the page's own button works on a paused video")
        await tab.exitPictureInPicture()
        XCTAssertFalse(tab.isPictureInPictureActive)

        tab.simulateVideo(playing: true)
        tab.simulateAutomaticPictureInPicture(allowed: false)
        entered = await tab.enterPictureInPicture(automatically: true)
        XCTAssertFalse(entered, "the site's setting blocks automatic entry")
        tab.simulateAutomaticPictureInPicture(allowed: true)
        entered = await tab.enterPictureInPicture(automatically: true)
        XCTAssertTrue(entered)
        XCTAssertTrue(tab.isPictureInPictureActive)
        entered = await tab.enterPictureInPicture(automatically: true)
        XCTAssertFalse(entered, "already in Picture in Picture")
    }

    func testViewSourceAsksForANewTab() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = engine.events()
        await tab.viewSource()
        let received = await take(1, from: events)
        XCTAssertEqual(received, [.newTabRequested(NewTabRequest(
            opener: tab.id, url: try url("view-source:https://page.example/a"), disposition: .foregroundTab, hasUserGesture: true
        ))])
    }

    // MARK: §5 Site origin and permission kinds

    func testSiteOriginNormalizesAndDerivesSecurity() throws {
        let origin = try XCTUnwrap(SiteOrigin(url: try url("HTTPS://Example.COM:8443/x")))
        XCTAssertEqual(origin, SiteOrigin(scheme: "https", host: "example.com", port: 8443))
        XCTAssertTrue(origin.isSecure)
        XCTAssertEqual(origin.displayHost, "example.com:8443")
        XCTAssertNil(SiteOrigin(url: try url("about:blank")))
        XCTAssertEqual(SitePermissionKind.allCases.count, 13, "the bridge's OACPermissionKind set")
    }

    // MARK: §6 Extra tab state

    func testNavigationReportsCommittedURLAndSecurity() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine, nil)
        let target = try url("http://plain.example")
        try await tab.load(target)
        let state = await tab.currentState()
        XCTAssertEqual(state.committedURL, target)
        XCTAssertEqual(state.security, SecurityLevel.none)
        try await tab.load(try url("https://secure.example"))
        let secure = await tab.currentState().security
        XCTAssertEqual(secure, .secure)
    }

    func testExtraStateChangesAreEventsAndInTheSnapshot() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        let color = RGBAColor(hex: 0x336699)
        tab.simulateFullscreen(true)
        tab.simulateThemeColor(color)
        tab.simulateCapture([.camera, .microphone])
        tab.simulateSecurity(.warning)
        tab.simulateHoveredLink(try url("https://link.example"))
        await tab.exitFullscreen()
        let received = await take(7, from: events)
        XCTAssertEqual(Array(received.dropFirst()), [
            .fullscreenChanged(true),
            .themeColorChanged(color),
            .captureStateChanged([.camera, .microphone]),
            .securityChanged(.warning),
            .hoveredLinkChanged(try url("https://link.example")),
            .fullscreenChanged(false),
        ])
        let state = await tab.currentState()
        XCTAssertEqual(state.themeColor, color)
        XCTAssertEqual(state.capture, [.camera, .microphone])
        XCTAssertFalse(state.isFullscreen)
    }

    // MARK: §8, §9 Downloads and extensions

    func testDownloadsSkeleton() async throws {
        let engine = FakeEngine()
        let downloads = engine.fakeDownloadService
        let events = downloads.events(profileID: profile)
        let item = DownloadItem(id: "d1", profileID: profile, sourceURL: try url("https://f.example/a.zip"),
                                suggestedFilename: "a.zip", startDate: Date(timeIntervalSince1970: 1))
        downloads.simulateDownload(item)
        await engine.downloads.pause("d1")
        await engine.downloads.confirm("d1", keep: true)
        await engine.downloads.remove("d1")
        await engine.downloads.setDefaultDirectory(try url("file:///tmp/"))
        let received = await take(4, from: events)
        guard case .updated(let paused) = received[1], case .updated(let kept) = received[2] else { return XCTFail("expected updates") }
        XCTAssertEqual(received.first, .added(item))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(kept.state, .complete)
        XCTAssertEqual(received.last, .removed(id: "d1"))
        let remaining = await engine.downloads.items(profileID: profile)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(downloads.defaultDirectory, try url("file:///tmp/"))
    }

    func testExtensionsSkeleton() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = engine.extensions.events(profileID: profile)
        try await engine.extensions.install(webStoreID: "abc", profileID: profile)
        var actions = await engine.extensions.actions(for: tab.id)
        XCTAssertEqual(actions.map(\.id), ["abc"])
        await engine.extensions.runAction("abc", on: tab.id)
        XCTAssertEqual(engine.fakeExtensionService.actionsRun, ["abc@\(tab.id)"])
        await engine.extensions.setEnabled(false, extensionID: "abc", profileID: profile)
        actions = await engine.extensions.actions(for: tab.id)
        XCTAssertTrue(actions.isEmpty)
        await engine.extensions.uninstall("abc", profileID: profile)
        let installed = await engine.extensions.installed(profileID: profile)
        XCTAssertTrue(installed.isEmpty)
        let received = await take(3, from: events)
        XCTAssertEqual(received, [.changed, .changed, .changed])
    }

    // MARK: §10 Lifetime

    func testShutdownClosesEverythingAndRefusesNewTabs() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let token = try XCTUnwrap(engine.simulateWindowOpen(from: tab.id, url: try url("https://p.example")))
        await engine.shutdown()
        XCTAssertTrue(engine.shutdownCalled)
        XCTAssertTrue(engine.tabIDs.isEmpty)
        XCTAssertFalse(engine.engineVersion.isEmpty)
        do {
            _ = try await engine.makeTab(TabConfiguration(profileID: profile))
            XCTFail("expected shuttingDown")
        } catch {
            XCTAssertEqual(error as? EngineError, .shuttingDown)
        }
        do {
            _ = try await engine.adoptTab(token, requestedID: nil)
            XCTFail("expected shuttingDown")
        } catch {
            XCTAssertEqual(error as? EngineError, .shuttingDown)
        }
    }

    func testProfileDataDeletionNeedsClosedTabs() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        do {
            try await engine.deleteProfileData(profile)
            XCTFail("expected invalidArgument")
        } catch {
            XCTAssertEqual(error as? EngineError, .invalidArgument)
        }
        await engine.closeTab(tab.id)
        try await engine.deleteProfileData(profile)
        XCTAssertEqual(engine.deletedProfileIDs, [profile])
        await engine.clearBrowsingData(profile, types: [.cookies, .cache], since: nil)
        XCTAssertEqual(engine.clearedBrowsingData.first?.types, [.cookies, .cache])
    }
}

/// `XCTUnwrap` for a value computed by an async expression.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
