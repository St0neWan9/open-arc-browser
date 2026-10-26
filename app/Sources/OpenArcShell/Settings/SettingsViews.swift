import SwiftUI
import OpenArcDesign
import AppKit
import OpenArcModel

/// The Settings window (⌘,, Open Arc ▸ Settings… [01 §Arc menu] observed). A standard macOS
/// settings window with a toolbar of panes; the window title follows the selected pane and the
/// window cannot be zoomed. [03] observed. `TabView` inside a `Settings` scene gives exactly that.
public struct SettingsWindowView: View {
    @ObservedObject var model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        TabView(selection: $model.selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                SettingsPaneView(pane: pane, model: model)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        .frame(width: SettingsTokens.windowWidth)
        .task { await model.observeSync() }
    }
}

/// Window size. Width [07 §6] observed (684; height follows the pane, 650 in Arc); the window
/// opens centered on the screen like Arc's ([07 §12] observed). B42.
enum SettingsTokens {
    static let windowWidth = CGFloat(Metrics.Settings.windowSize.width)
    /// Pane height that makes the window 650 tall ([07 §6] observed) under the 80 pt title bar and
    /// toolbar of the settings window (measured on ours: 640 tall with a 560 pane). B42.
    static let paneMinHeight = CGFloat(Metrics.Settings.windowSize.height) - 80
    static let profileListWidth: CGFloat = 180
    static let iconTileSize: CGFloat = 96
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch pane {
            case .account: AccountPane(model: model)
            case .general: GeneralPane(model: model)
            case .profiles: ProfilesPane(model: model)
            case .links: LinksPane(model: model)
            case .shortcuts: ShortcutsPane(model: model)
            case .icon: IconPane()
            case .advanced: AdvancedPane(model: model)
            }
        }
        .frame(minHeight: SettingsTokens.paneMinHeight, alignment: .top)
    }
}

// MARK: - Building blocks

/// A catalog toggle with no backing feature: shows its default value, disabled.
struct PendingToggle: View {
    let id: String

    var body: some View {
        let control = SettingsCatalog.control(id)
        if case .toggle(let value) = control.kind {
            Toggle(control.label, isOn: .constant(value)).disabled(!control.isEnabled)
        }
    }
}

/// A catalog button; disabled unless `action` is given and the control is live.
struct CatalogButton: View {
    let id: String
    var action: (() -> Void)?

    var body: some View {
        let control = SettingsCatalog.control(id)
        Button(control.label) { action?() }
            .disabled(!control.isEnabled || action == nil)
    }
}

/// A catalog dropdown with no backing feature: shows only its default value, disabled.
struct PendingPicker: View {
    let id: String

    var body: some View {
        let control = SettingsCatalog.control(id)
        if case .picker(let value) = control.kind {
            Picker(control.label, selection: .constant(value)) { Text(value).tag(value) }
                .disabled(!control.isEnabled)
        }
    }
}

// MARK: - Account card

/// "Arc isn’t your default browser" + "Make Arc your default". [03 §账号卡] observed. While we are
/// the default the button goes away and the line says so (inferred).
struct DefaultBrowserBanner: View {
    @ObservedObject var model: DefaultBrowserModel

    var body: some View {
        Section {
            HStack {
                Text(model.statusText)
                Spacer()
                if !model.isDefault {
                    CatalogButton(id: "account.makeDefault") { Task { await model.makeDefault() } }
                        .disabled(model.isRequesting)
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

/// Replaces Arc's account card with iCloud sync. [03 §账号卡] observed: "Sync Sidebar" toggle and
/// "Last synced" line. Membership card, referral and account management are out of scope.
struct AccountPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            DefaultBrowserBanner(model: model.defaultBrowser)
            SyncCardView(model: model, sync: model.sync)
        }
        .formStyle(.grouped)
    }
}

/// The iCloud part of the account card. Observes the sync controller, so status changes redraw it.
struct SyncCardView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var sync: SidebarSyncController

    var body: some View {
        let card = sync.card
        Section("iCloud") {
            Toggle(
                SettingsCatalog.control("account.syncSidebar").label,
                isOn: Binding(get: { sync.isEnabled }, set: { model.setSidebarSync($0) })
            )
            .disabled(!card.isToggleEnabled)
            HStack {
                // "Last synced" is relative; the timeline redraws it every minute.
                TimelineView(.everyMinute) { _ in
                    Text(sync.card.statusLine)
                        .font(Typography.settingsBody.font)
                        .foregroundStyle(card.isWarning ? Color.orange : Color.secondary)
                }
                Spacer()
                if let action = card.action {
                    Button(action.title) { model.performSyncAction(action) }
                }
            }
            // Our own wording: sync goes to the user's private iCloud database (CloudKit).
            Text("Your sidebar syncs through your private iCloud account.")
                .font(Typography.settingsBody.font)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                PendingToggle(id: "general.info")
                PendingToggle(id: "general.warnBeforeQuitting")
            }
            Section("Previews") {
                CatalogButton(id: "general.previewsSettings")
            }
            Section {
                Text("Your default search engine, tab archiving and download location are set per Profile.")
                    .foregroundStyle(.secondary)
                CatalogButton(id: "general.profileSettings") { model.openProfileSettings() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Profiles

struct ProfilesPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var sidebar: SidebarViewModel

    init(model: SettingsModel) {
        self.model = model
        self.sidebar = model.shell.sidebar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CatalogButton(id: "profiles.learnMore")
            }
            HStack(alignment: .top, spacing: 12) {
                profileList
                profileSettings
            }
        }
        .padding(20)
        .sheet(isPresented: Binding(
            get: { model.profilePendingDeletion != nil },
            set: { if !$0 { model.cancelProfileDeletion() } }
        )) {
            DeleteProfileSheet(model: model)
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { model.editedProfileID }, set: { model.selectedProfileID = $0 })) {
                Section("Your Profiles") {
                    ForEach(model.profileRows) { row in
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.detail).font(Typography.settingsCaption.font).foregroundStyle(.secondary)
                        }
                        .tag(Optional(row.id))
                    }
                }
            }
            .listStyle(.bordered)
            HStack(spacing: 0) {
                Button { model.addProfile() } label: { Image(systemName: "plus") }
                    .help(SettingsCatalog.control("profiles.add").label)
                // Enabled only when the edited profile can be deleted; otherwise the reason shows.
                // [03 §Profiles] observed: "The Default Profile cannot be deleted."
                Button { model.requestDeleteEditedProfile() } label: { Image(systemName: "minus") }
                    .disabled(!model.canDeleteEditedProfile)
                    .help(model.profileDeletionBlockedReason ?? SettingsCatalog.control("profiles.remove").label)
            }
            .buttonStyle(.borderless)
            .padding(4)
            if let reason = model.profileDeletionBlockedReason {
                Text(reason)
                    .font(Typography.settingsCaption.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: SettingsTokens.profileListWidth)
    }

    private var profileSettings: some View {
        Form {
            Section {
                Picker(SettingsCatalog.control("profiles.searchEngine").label, selection: Binding(
                    get: { model.searchEngine }, set: { model.searchEngine = $0 }
                )) {
                    ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Manage search") { CatalogButton(id: "profiles.searchSettings") }
                PendingToggle(id: "profiles.searchSuggestions")
                // ⓘ: the spec notes an info button next to this dropdown; its text was not recorded.
                Picker(SettingsCatalog.control("profiles.archiveTabsAfter").label, selection: Binding(
                    get: { model.archiveLifetime }, set: { model.archiveLifetime = $0 }
                )) {
                    ForEach(ArchiveLifetime.allCases) { Text($0.displayName).tag($0) }
                }
                .help("Unpinned tabs in Today are archived after they have been idle this long.")
                PendingPicker(id: "profiles.newDocuments")
                PendingPicker(id: "profiles.downloadLocation")
            }
            Section("Your Data and Settings") {
                ForEach(["profiles.privacy", "profiles.passwords", "profiles.creditCards",
                         "profiles.notifications", "profiles.autofill", "profiles.clearBrowsingData"], id: \.self) { id in
                    let control = SettingsCatalog.control(id)
                    Button {} label: {
                        HStack {
                            Text(control.label)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!control.isEnabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Links

struct LinksPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text("Little Arc is a smaller, simpler Open Arc window for quick lookups.")
                    .foregroundStyle(.secondary)
                PendingToggle(id: "links.littleArcHotKey")
                PendingToggle(id: "links.littleArcModifierClick")
                Toggle(
                    SettingsCatalog.control("links.littleArcExternal").label,
                    isOn: Binding(get: { model.opensExternalLinksInLittleArc }, set: { model.opensExternalLinksInLittleArc = $0 })
                )
                PendingPicker(id: "links.archiveLittleArcsAfter")
            } header: { Text("Little Arc") }
            Section {
                Text("Peek lets you preview a link without opening a new tab.")
                    .foregroundStyle(.secondary)
                PendingToggle(id: "links.peekShiftClick")
                PendingToggle(id: "links.peekOtherSites")
            } header: { Text("Peek") }
            Section {
                LabeledContent("Choose where links open inside Open Arc") {
                    CatalogButton(id: "links.airTrafficControl")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

/// Read-only list of the shortcuts Open Arc implements, grouped as in `02`. Customization is out
/// of scope for now (plan B12, inferred), so its controls are disabled.
struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(SettingsCatalog.control("shortcuts.search").label, text: $model.shortcutQuery)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(model.shortcutGroups) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            LabeledContent(entry.action) {
                                Text(entry.keys).monospaced().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 260)
            HStack {
                CatalogButton(id: "shortcuts.basics")
                Spacer()
                PendingPicker(id: "shortcuts.priority").fixedSize()
                CatalogButton(id: "shortcuts.custom")
                CatalogButton(id: "shortcuts.reset")
            }
        }
        .padding(20)
    }
}

// MARK: - Icon

/// [03 §Icon] observed: a list of app icons with a CURRENT ICON marker. Our icon variants are not
/// designed yet, so the grid holds a single placeholder default.
struct IconPane: View {
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: SettingsTokens.iconTileSize, height: SettingsTokens.iconTileSize)
                .overlay(Image(systemName: "circle.hexagongrid").font(.system(size: 40)).foregroundStyle(.white))
            Text("Default")
            Text("CURRENT ICON").font(.caption2.bold()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(20)
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @ObservedObject var model: SettingsModel

    static let toggleIDs = [
        "advanced.soundEffects", "advanced.reorderHaptics", "advanced.restoreWindows",
        "advanced.windowDragging", "advanced.showFullURL", "advanced.pictureInPicture",
        "advanced.themeData", "advanced.boosts",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.toggleIDs, id: \.self) { id in
                    if id == "advanced.restoreWindows" {
                        // [03 §Advanced] observed, off by default. Live since B14.
                        Toggle(SettingsCatalog.control(id).label, isOn: Binding(
                            get: { model.restoresWindows }, set: { model.restoresWindows = $0 }
                        ))
                    } else if id == "advanced.showFullURL" {
                        // [03 §Advanced] observed, off by default; [06 §17.2] the toolbar shows the
                        // address without its scheme. Live since B43; every window follows.
                        WebToolbarFullURLToggle(settings: model.shell.webToolbar)
                    } else if id == "advanced.pictureInPicture" {
                        // [03 §Advanced] observed, on by default. Live since C15.
                        Toggle(SettingsCatalog.control(id).label, isOn: Binding(
                            get: { model.entersPictureInPictureOnLeavingVideoTab },
                            set: { model.entersPictureInPictureOnLeavingVideoTab = $0 }
                        ))
                    } else {
                        PendingToggle(id: id)
                    }
                }
            }
            Section {
                CatalogButton(id: "advanced.moreSettings")
                CatalogButton(id: "advanced.resetTranslatePrompts")
                CatalogButton(id: "advanced.exportData")
            }
            // Plan C16: the engine's ad blocker; hidden when the engine has no filter ruleset.
            if let version = model.adBlockingRulesetVersion {
                Section {
                    Toggle(SettingsCatalog.control("advanced.adBlocking").label, isOn: Binding(
                        get: { model.isAdBlockingOn },
                        set: { isOn in Task { await model.setAdBlocking(isOn) } }
                    ))
                } footer: {
                    Text("Filter lists: EasyList and EasyPrivacy (\(version)). Sites can be allowed one by one in the site controls.")
                        .foregroundStyle(.secondary)
                }
            }
            // Plan D7: automatic updates (Sparkle). Not in [03 §Advanced]; our addition.
            UpdateSettingsSection(model: model.updates)
            Section("Crash Reports") {
                // Plan decision Q8: stored locally only, never uploaded.
                Text("Crash reports are stored locally on this Mac and are never sent anywhere.")
                    .foregroundStyle(.secondary)
                CatalogButton(id: "advanced.showCrashReports") { model.showCrashReports() }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadAdBlocking() }
    }
}

/// Owns the Settings window's model for the lifetime of the Settings scene.
struct SettingsRootView: View {
    @StateObject private var model: SettingsModel

    init(shell: ShellModel) {
        _model = StateObject(wrappedValue: SettingsModel(shell: shell))
    }

    var body: some View {
        SettingsWindowView(model: model)
    }
}

/// "Delete this Profile" confirmation. [06 §16.3] observed: app icon, title, body naming the
/// profile, a text field for its name, Cancel and a red Delete that stays disabled until the
/// typed text equals the name. Geometry: our own (the observed sheet is 450 × 349).
struct DeleteProfileSheet: View {
    @ObservedObject var model: SettingsModel
    @State private var typed = ""

    var body: some View {
        let name = model.profilePendingDeletionName ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 62, height: 62)
            Text("Delete this Profile").font(.title3.weight(.semibold))
            Text(SettingsModel.profileDeletionMessage(name: name))
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.confirmProfileDeletion(typed: typed) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelProfileDeletion() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { model.confirmProfileDeletion(typed: typed) }
                    .tint(.red)
                    .disabled(!model.canConfirmProfileDeletion(typed: typed))
            }
        }
        .padding(38)
        .frame(width: 450)
        .accessibilityIdentifier("openarc.deleteProfile")
    }
}

/// "Show full URL when Toolbar is enabled": the shared toolbar setting (B43).
struct WebToolbarFullURLToggle: View {
    @ObservedObject var settings: WebToolbarSettings

    var body: some View {
        Toggle(SettingsCatalog.control("advanced.showFullURL").label, isOn: $settings.showsFullURL)
    }
}
