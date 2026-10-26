// Type-checked (never run or linked) by chromium-bridge/check-headers.sh. It shows how the Swift
// target `OpenArcChromium` (plan C8) is expected to see the OpenArcCore API, and fails the check if
// a Swift name, nullability or actor annotation in the headers changes shape.
//
// The real wrapper also imports OpenArcEngine; this file stays standalone so the check needs
// nothing but the SDK.

import Foundation
import OpenArcCore

@MainActor
final class ImportCheckDelegate: NSObject, OACTabDelegate, OACDialogDelegate, OACApplicationDelegate {
    func tab(_ tab: OACTab, didChangeURL url: URL?) {}
    func tab(_ tab: OACTab, didChangeTitle title: String) {}
    func tab(_ tab: OACTab, didChangeLoading isLoading: Bool, progress: Double) {}
    func tabDidClose(_ tab: OACTab) {}
    func tab(_ tab: OACTab, didRequestNewTab request: OACNewTabRequest) {
        if request.hasPendingContents {
            _ = try? request.adopt(identifier: UUID())
        } else {
            request.decline()
        }
    }
    func tab(_ tab: OACTab, runJavaScriptDialog request: OACJavaScriptDialogRequest) -> Bool {
        request.accept(promptText: nil, suppressFurtherDialogs: false)
        return true
    }
    func tab(_ tab: OACTab, requestPermission request: OACPermissionRequest) -> Bool {
        request.deny(remembering: false)
        return true
    }
}

@MainActor
func exerciseAPI(delegate: ImportCheckDelegate) throws {
    let app = OACApplication.shared
    let configuration = OACApplicationConfiguration(userDataDirectory: URL(fileURLWithPath: "/tmp/oac"))
    configuration.arguments = ProcessInfo.processInfo.arguments
    try app.start(configuration: configuration)
    app.delegate = delegate
    let _: String = app.chromiumVersion

    app.loadProfile(identifier: UUID()) { profile, error in
        guard let profile else { _ = error; return }
        let otr: OACProfile = profile.offTheRecordProfile
        let tabConfiguration = OACTabConfiguration(profile: otr)
        tabConfiguration.initialURL = URL(string: "https://example.com")
        tabConfiguration.requestedIdentifier = UUID()
        guard let tab = try? OACTab(configuration: tabConfiguration) else { return }
        tab.delegate = delegate
        tab.dialogDelegate = delegate
        let state: OACTabState = tab.state
        _ = (state.url, state.title, state.isLoading, state.loadProgress, state.canGoBack,
             state.audioState.contains(.audible), state.securityLevel == .secure)
        try? tab.load(URL(string: "https://example.org")!)
        try? tab.goBack()
        try? tab.reload(bypassingCache: false)
        tab.setMuted(true)
        let view: NSView? = tab.nativeView
        _ = view as AnyObject?
        tab.snapshot(maxPixelSize: 512) { png, size, error in _ = (png, size, error) }
        _ = tab.find("needle", options: OACFindOptions())
        tab.showDevTools(panel: nil)
        tab.stopFinding(keepingSelection: false)
        try? tab.setZoomFactor(1.25)
        tab.close()
        _ = OACTab.tab(identifier: UUID())

        profile.siteSettings.settings(for: OACOrigin(scheme: "https", host: "example.com", port: nil)) { s in
            _ = (profile.originalProfile, s.isDeveloperModeEnabled, s.decision(for: .camera), s.cookieCount)
        }
        profile.siteSettings.setDecision(.allow, for: .camera, origin: OACOrigin(scheme: "https", host: "example.com", port: nil))
        _ = profile.downloads.items
        _ = profile.extensions.installedExtensions
    }
}

@MainActor
func exerciseShutdown() {
    OACApplication.shared.shutdown {}
    let error = NSError(domain: OACErrorDomain, code: OACError.tabClosed.rawValue)
    _ = error
}
