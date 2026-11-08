import SwiftUI
import AppKit
import OpenArcDesign

// The places where the user sees and changes usage-data sharing (plan B194; our own design and
// wording): Settings ▸ General ▸ Privacy & Usage Data, the "What is shared?" sheet, the one-time
// notice in the first normal window, and the card on onboarding's last page.

/// Texts of the usage-data controls. Our own wording.
enum UsageDataTexts {
    static let sectionTitle = "Privacy & Usage Data"
    static let toggle = "Share usage data"
    static let settingsDetail = "Send basic app and feature usage to PostHog in the US. Browsing content is never included. This setting applies only to this Mac."
    static let offDetail = "Usage data sharing is off."
    static let whatIsShared = "What is shared?"
    static let privacyPolicy = "Privacy Policy"

    static let noticeTitle = "Help improve Open Arc"
    static let noticeBody = "Basic usage data sharing is on by default. Data goes to PostHog in the US; browsing content is never included. You can turn it off anytime in Settings → General."
    static let turnOff = "Turn off"
    static let reviewSettings = "Review settings"
    static let dismiss = "Dismiss"

    static let onboardingBody = "Share basic usage data to help us understand which features are useful. Data is sent to PostHog in the US. We never include the websites you visit, page contents, searches, or passwords."
    static let onboardingNote = "Enabled by default. You can turn it off here or anytime in Settings → General. Applies only to this Mac."

    /// The "What is shared?" sheet, readable offline.
    static let detailsTitle = "What is shared?"
    static let detailsSections: [(title: String, body: String)] = [
        ("Events", "That the app was used on a day; which of these features you used that day: Spaces, Split View, Peek, the command bar, archiving tabs; whether an Arc import succeeded; and the archive interval you chose. At most 20 events a day."),
        ("With each event", "The app version, the macOS major version, the processor type and a random identifier for this installation, so returning installations can be counted."),
        ("Never", "Websites, addresses, page titles or contents, searches, bookmarks, passwords, the clipboard, file names, names of Spaces or Profiles, email addresses, Apple Account or iCloud identifiers, and anything from incognito windows."),
        ("Where it goes", "PostHog Cloud in the US. Any internet request reveals an IP address to the receiving service; Open Arc asks PostHog not to derive a location from it. Events are kept for up to one year."),
        ("Your choice", "Turn sharing off in Settings → General at any time; it applies only to this Mac. Turning it off stops sending at once and removes events waiting to be sent and the installation identifier. Events already sent are not erased automatically."),
    ]
}

// MARK: - Settings ▸ General

/// The General pane's "Privacy & Usage Data" card.
struct UsageDataSettingsCard: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var analytics: UsageAnalytics
    @State private var showsDetails = false

    var body: some View {
        SettingsCaption(text: UsageDataTexts.sectionTitle)
        SettingsCard {
            SettingsToggleRow(
                label: SettingsCatalog.control("general.shareUsageData").label,
                isOn: Binding(get: { analytics.isSharingEnabled }, set: { analytics.setSharingEnabled($0) }),
                subtitle: analytics.isSharingEnabled ? UsageDataTexts.settingsDetail : UsageDataTexts.offDetail
            )
            .accessibilityIdentifier("openarc.settings.shareUsageData")
            SettingsDivider()
            SettingsControlRow(label: "Learn more") {
                HStack(spacing: 8) {
                    Button(UsageDataTexts.whatIsShared) { showsDetails = true }
                        .buttonStyle(SettingsButtonStyle())
                    Button(UsageDataTexts.privacyPolicy) { model.openPrivacyPolicy() }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
        .sheet(isPresented: $showsDetails) { UsageDataDetailsSheet { showsDetails = false } }
    }
}

/// "What is shared?": the full list, available offline.
struct UsageDataDetailsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(UsageDataTexts.detailsTitle).font(.title3.weight(.semibold))
            ForEach(UsageDataTexts.detailsSections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.system(size: 13, weight: .semibold))
                    Text(section.body).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .accessibilityIdentifier("openarc.usageData.details")
    }
}

// MARK: - The one-time notice

/// The notice in the first normal window for an installation that has not seen it. Non-modal, at
/// the window's bottom right; collection starts only once it is on screen.
struct UsageDataNoticeLayer: View {
    let model: ShellModel
    @ObservedObject var analytics: UsageAnalytics
    @ObservedObject var onboarding: OnboardingModel

    var body: some View {
        if shouldShow {
            UsageDataNoticeCard(
                turnOff: { analytics.setSharingEnabled(false); analytics.dismissNotice() },
                review: {
                    analytics.dismissNotice()
                    model.controller.requestUsageDataSettings()
                    model.openSettingsWindow?()
                },
                dismiss: { analytics.dismissNotice() }
            )
            .onAppear { analytics.noticeDidAppear() }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Only in the active normal window, never with onboarding on screen or in incognito.
    private var shouldShow: Bool {
        guard model.isBrowserWindow, !model.controller.isOffTheRecord, !onboarding.isPresented,
              model.controller.activeWindow === model else { return false }
        return analytics.isNoticeOnScreen || analytics.needsNotice
    }
}

struct UsageDataNoticeCard: View {
    let turnOff: () -> Void
    let review: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UsageDataTexts.noticeTitle).font(.system(size: 13, weight: .semibold))
            Text(UsageDataTexts.noticeBody).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(UsageDataTexts.turnOff, action: turnOff)
                    .accessibilityIdentifier("openarc.usageData.notice.turnOff")
                Button(UsageDataTexts.reviewSettings, action: review)
                Spacer(minLength: 0)
                Button(UsageDataTexts.dismiss, action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.usageData.notice")
    }
}

// MARK: - Onboarding

/// The card on onboarding's last page, above Start Browsing.
struct OnboardingUsageDataCard: View {
    @ObservedObject var onboarding: OnboardingModel
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UsageDataTexts.noticeTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.black)
            Text(UsageDataTexts.onboardingBody).font(.system(size: 12)).foregroundStyle(Color.black.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(UsageDataTexts.toggle, isOn: Binding(
                get: { onboarding.shareUsageDataDraft }, set: { onboarding.shareUsageDataDraft = $0 }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 12, weight: .medium))
            .accessibilityIdentifier("openarc.onboarding.shareUsageData")
            Text(UsageDataTexts.onboardingNote).font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Button(UsageDataTexts.whatIsShared) { showsDetails = true }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.04)))
        .sheet(isPresented: $showsDetails) { UsageDataDetailsSheet { showsDetails = false } }
    }
}
