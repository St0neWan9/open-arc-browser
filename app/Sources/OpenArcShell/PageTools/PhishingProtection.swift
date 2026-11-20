import Foundation
import SwiftUI
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Phishing protection (plan B234). The list and how it is published: OpenArcEngine/PhishingList.swift.
//
// When a tab of a window starts showing an http(s) address on a listed host, the shell stops the
// load and covers the page with a warning: "Go Back" (the previous page, or a blank one), or
// "Continue to site" (shows the page; the host stays allowed until the app quits). Matching
// happens on this Mac against the downloaded list; no visited address leaves it. The switch is
// Settings ▸ General "Warn about phishing sites" (on by default); while it is off, no list update
// is fetched either. Our own design throughout (Arc's equivalent is Chromium's Safe Browsing page,
// which we do not ship, Q22).

@MainActor
public final class PhishingProtection: ObservableObject {
    /// Tabs whose page is covered, with the flagged address.
    @Published public private(set) var flagged: [EngineTabID: URL] = [:]
    /// The list in use; nil before the first download (protection then flags nothing).
    @Published public private(set) var list: PhishingList?

    private let preferences: AppPreferences
    private let store: AdBlockRulesetStore?
    private var allowedHosts: Set<String> = []
    private var scheduler: AdBlockRulesetUpdateScheduler?
    private var activeVersion: String?

    /// `directory`: where downloaded lists are kept; nil (tests, previews) never downloads.
    public init(preferences: AppPreferences, directory: URL?) {
        self.preferences = preferences
        store = directory.map(AdBlockRulesetStore.init(root:))
    }

    /// For tests.
    init(preferences: AppPreferences, list: PhishingList?) {
        self.preferences = preferences
        store = nil
        self.list = list
    }

    public var isEnabled: Bool { preferences.warnsAboutPhishingSites }

    /// Loads the stored list and starts the update schedule (the ad-block ruleset's rules: first
    /// check 30 s after launch, then daily, only while the switch is on).
    public func start() {
        guard scheduler == nil, let store else { return }
        Task { [weak self] in
            let loaded = await Task.detached { Self.readList(in: store) }.value
            guard let self, let loaded, self.activeVersion == nil else { return }
            self.list = loaded.list
            self.activeVersion = loaded.version
        }
        let updater = AdBlockRulesetUpdater(manifestURL: PhishingList.hostedManifestURL, store: store,
                                            manifestType: PhishingList.typeIdentifier,
                                            maxListBytes: PhishingList.maxListBytes)
        let scheduler = AdBlockRulesetUpdateScheduler(
            isAdBlockingEnabled: { [weak self] in self?.isEnabled ?? false },
            check: { [weak self] in await self?.checkOnce(updater) ?? false }
        )
        self.scheduler = scheduler
        scheduler.start()
    }

    public func stop() { scheduler?.stop() }

    /// The Settings switch changed.
    public func switchChanged() {
        scheduler?.adBlockingChanged(isOn: isEnabled)
        if !isEnabled { flagged.removeAll() }
    }

    private func checkOnce(_ updater: AdBlockRulesetUpdater) async -> Bool {
        let outcome = await updater.check(activeVersion: activeVersion)
        if case .installed(let version, let directory) = outcome,
           let data = try? Data(contentsOf: directory.appendingPathComponent(PhishingList.listFileName)),
           let list = PhishingList(data: data) {
            self.list = list
            activeVersion = version
        }
        return true
    }

    nonisolated static func readList(in store: AdBlockRulesetStore) -> (list: PhishingList, version: String)? {
        guard let directory = store.currentDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(PhishingList.listFileName)),
              let list = PhishingList(data: data),
              let version = try? String(contentsOf: directory.appendingPathComponent("ruleset.version"), encoding: .utf8)
        else { return nil }
        return (list, version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Tab `tab` started showing `url`. True when the page must be stopped and covered.
    @discardableResult
    func addressChanged(_ url: URL?, in tab: EngineTabID) -> Bool {
        guard let url, isEnabled, let list, list.contains(url),
              let host = url.host?.lowercased(), !allowedHosts.contains(host) else {
            if flagged[tab] != nil, flagged[tab]?.host != url?.host { flagged[tab] = nil }
            return false
        }
        if flagged[tab] != url { flagged[tab] = url }
        return true
    }

    /// "Continue to site": the host stays allowed for this run; returns the address to load.
    func proceed(in tab: EngineTabID) -> URL? {
        guard let url = flagged.removeValue(forKey: tab) else { return nil }
        if let host = url.host?.lowercased() { allowedHosts.insert(host) }
        return url
    }

    /// "Go Back" (or the tab closed): the cover goes.
    func clear(_ tab: EngineTabID) {
        flagged[tab] = nil
    }
}

// MARK: - View

private struct PhishingProtectionKey: EnvironmentKey {
    static let defaultValue: PhishingProtection? = nil
}

extension EnvironmentValues {
    /// The window's phishing protection; nil shows no warnings (previews).
    var phishingProtection: PhishingProtection? {
        get { self[PhishingProtectionKey.self] }
        set { self[PhishingProtectionKey.self] = newValue }
    }
}

/// The warning over a flagged page. Our own look: a red-tinted full panel, like a browser's
/// deceptive-site page.
struct PhishingWarningOverlay: View {
    @ObservedObject var protection: PhishingProtection
    let tab: any BrowserTab

    var body: some View {
        if let url = protection.flagged[tab.id] {
            let t = PhishingWarningTokens.self
            VStack(spacing: t.spacing) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: t.glyphSize))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text(t.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(t.message(host: url.host ?? url.absoluteString))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: t.messageWidth)
                Button(t.backLabel) { goBack() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("openarc.webPanel.phishing.back")
                Button(t.proceedLabel) { proceed() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .underline()
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("openarc.webPanel.phishing.proceed")
            }
            .padding(t.spacing * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.background.swiftUI)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("openarc.webPanel.phishing")
        }
    }

    private func goBack() {
        protection.clear(tab.id)
        let tab = tab
        Task {
            if (await tab.currentState()).navigation.canGoBack {
                try? await tab.goBack()
            } else if let blank = URL(string: "about:blank") {
                try? await tab.load(blank)
            }
        }
    }

    private func proceed() {
        guard let url = protection.proceed(in: tab.id) else { return }
        let tab = tab
        Task { try? await tab.load(url) }
    }
}

/// Warning page constants. All our own.
enum PhishingWarningTokens {
    static let title = "Deceptive site ahead"
    static func message(host: String) -> String {
        "\(host) is on a list of phishing sites. It may try to trick you into giving away passwords, "
            + "card numbers or other personal information."
    }
    static let backLabel = "Go Back"
    static let proceedLabel = "Continue to site (unsafe)"
    static let background = RGBAColor(hex: 0xB3261E)
    static let glyphSize: CGFloat = 44
    static let spacing: CGFloat = 14
    static let messageWidth: CGFloat = 440
}
