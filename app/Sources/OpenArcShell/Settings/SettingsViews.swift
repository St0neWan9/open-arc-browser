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
        // Always light (user decision, 2026-10-28; Arc's is dark, [07 §6] observed), 37 pt
        // toggle rows ([07 §6] observed, B91).
        .modifier(SettingsWindowChrome())
        .task { await model.observeSync() }
    }
}

/// Window size. Width [07 §6] observed (684; height follows the pane, 650 in Arc); the window
/// opens centered on the screen like Arc's ([07 §12] observed). B42.
enum SettingsTokens {
    static let windowWidth = CGFloat(Metrics.Settings.windowSize.width)
    /// Title bar plus toolbar above the pane: the system title bar and the 56 pt toolbar
    /// ([07 §6] observed; the settings toolbar measures 56 on ours too, B91).
    static let chromeHeight = CGFloat(Metrics.Settings.titleBarHeight + Metrics.Settings.toolbarHeight)
    /// Pane height that makes the window 650 tall. [07 §6] observed.
    static let paneMinHeight = CGFloat(Metrics.Settings.windowSize.height) - chromeHeight
    /// Space a grouped form row adds around its content (measured on ours: 10.75 above and below
    /// a 16 pt switch, a 37.5 pt pitch). B91.
    static let groupedRowChrome: CGFloat = 21.5
    /// Toggle content height that gives the 37 pt toggle row pitch. [07 §6] observed (37).
    static let toggleContentHeight = CGFloat(Metrics.Settings.toggleRowPitch) - groupedRowChrome
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
            case .icon: IconPane(icons: model.appIcon)
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
            if sync.canDeleteServerData {
                // D12: wipes our iCloud data after a confirmation.
                Button(SyncCardState.DeleteServerData.buttonTitle, role: .destructive) { isConfirmingDelete = true }
                    .confirmationDialog(SyncCardState.DeleteServerData.confirmTitle, isPresented: $isConfirmingDelete) {
                        Button(SyncCardState.DeleteServerData.confirmButton, role: .destructive) { model.deleteICloudData() }
                    } message: {
                        Text(SyncCardState.DeleteServerData.confirmMessage)
                    }
            }
        }
    }

    @State private var isConfirmingDelete = false
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                PendingToggle(id: "general.info")
                // [03 §General] observed, on by default. Live since B68.
                Toggle(SettingsCatalog.control("general.warnBeforeQuitting").label, isOn: Binding(
                    get: { model.warnsBeforeQuitting }, set: { model.warnsBeforeQuitting = $0 }
                ))
            }
            Section("Previews") {
                // Opens Links ▸ Peek (B84).
                CatalogButton(id: "general.previewsSettings") { model.openPreviewsSettings() }
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
                CatalogButton(id: "profiles.learnMore") { model.openProfilesHelp() }
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
        .sheet(isPresented: Binding(
            get: { model.profileClearingData != nil },
            set: { if !$0 { model.cancelClearBrowsingData() } }
        )) {
            ClearBrowsingDataSheet(model: model)
        }
        // The edited profile's download folder comes from the engine (B83).
        .task(id: model.editedProfileID) { await model.loadDownloadDirectory() }
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
                LabeledContent("Manage search") {
                    CatalogButton(id: "profiles.searchSettings") { model.openEnginePage(.searchSettings) }
                        .disabled(!model.canOpenEditedProfilePages)
                }
                Toggle(SettingsCatalog.control("profiles.searchSuggestions").label, isOn: Binding(
                    get: { model.includesSearchSuggestions }, set: { model.includesSearchSuggestions = $0 }
                ))
                // ⓘ: the spec notes an info button next to this dropdown; its text was not recorded.
                Picker(SettingsCatalog.control("profiles.archiveTabsAfter").label, selection: Binding(
                    get: { model.archiveLifetime }, set: { model.archiveLifetime = $0 }
                )) {
                    ForEach(ArchiveLifetime.allCases) { Text($0.displayName).tag($0) }
                }
                .help("Unpinned tabs in Today are archived after they have been idle this long.")
                PendingPicker(id: "profiles.newDocuments")
                DownloadLocationPicker(model: model)
            }
            Section {
                ForEach(Self.dataRows, id: \.self) { page in
                    DataRow(id: page.controlID) { model.openEnginePage(page) }
                        .disabled(!model.canOpenEditedProfilePages)
                }
                DataRow(id: "profiles.clearBrowsingData") { model.requestClearBrowsingData() }
            } header: {
                Text("Your Data and Settings")
            } footer: {
                if !model.canOpenEditedProfilePages {
                    // A page opens in a tab of a Space that uses this Profile (inferred).
                    Text("Assign this Profile to a Space to manage its data.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// [03 §Profiles] observed order: Privacy and Security · Passwords · Credit Cards ·
    /// Notifications · Autofill, then Clear Browsing Data.
    static let dataRows: [ProfileEnginePage] = [.privacy, .passwords, .creditCards, .notifications, .autofill]
}

/// A "Your Data and Settings" row: label and an arrow; the whole row is the button.
/// [03 §Profiles] observed: each item is a row with an arrow.
struct DataRow: View {
    let id: String
    let action: () -> Void

    var body: some View {
        let control = SettingsCatalog.control(id)
        Button(action: action) {
            HStack {
                Text(control.label)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!control.isEnabled)
    }
}

/// "Download location": the folder, Downloads, and "Other…". [03 §Profiles] observed dropdown
/// with default Downloads; the other entries are inferred (a Finder-style folder menu).
struct DownloadLocationPicker: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Picker(SettingsCatalog.control("profiles.downloadLocation").label, selection: Binding(
            get: { DownloadLocationChoice.folder(model.downloadDirectory.standardizedFileURL) },
            set: { choice in Task { await model.chooseDownloadLocation(choice) } }
        )) {
            ForEach(model.downloadLocationChoices, id: \.self) { choice in
                switch choice {
                case .folder(let url):
                    Label {
                        Text(SettingsModel.displayName(of: url))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    }
                    .tag(choice)
                case .other:
                    Text("Other…").tag(choice)
                }
            }
        }
        .help(model.downloadDirectory.path)
    }
}

/// "Clear Browsing Data" for one Profile. [03 §Profiles] observed row; the sheet itself is ours
/// (inferred, Chromium's choices): a time range, the kinds of data, Cancel and "Clear data".
struct ClearBrowsingDataSheet: View {
    @ObservedObject var model: SettingsModel
    @State private var range = ClearBrowsingDataRange.default
    @State private var kinds = ClearBrowsingDataKind.defaultSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear Browsing Data").font(.title3.weight(.semibold))
            Text("Removes data of the Profile “\(model.profileClearingDataName ?? "")” from this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Time range", selection: $range) {
                ForEach(ClearBrowsingDataRange.allCases) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ClearBrowsingDataKind.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { kinds.contains(kind) },
                        set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                if model.isClearingBrowsingData { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelClearBrowsingData() }
                    .keyboardShortcut(.cancelAction)
                Button("Clear data") { Task { await model.confirmClearBrowsingData(range: range, kinds: kinds) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kinds.isEmpty || model.isClearingBrowsingData)
            }
        }
        .padding(24)
        .frame(width: 420)
        .accessibilityIdentifier("openarc.clearBrowsingData")
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
                Toggle(
                    SettingsCatalog.control("links.littleArcHotKey").label,
                    isOn: Binding(get: { model.opensLittleArcWithGlobalHotKey }, set: { model.opensLittleArcWithGlobalHotKey = $0 })
                )
                Toggle(
                    SettingsCatalog.control("links.littleArcModifierClick").label,
                    isOn: Binding(get: { model.opensLittleArcOnOptionCommandClick }, set: { model.opensLittleArcOnOptionCommandClick = $0 })
                )
                Toggle(
                    SettingsCatalog.control("links.littleArcExternal").label,
                    isOn: Binding(get: { model.opensExternalLinksInLittleArc }, set: { model.opensExternalLinksInLittleArc = $0 })
                )
                Picker(SettingsCatalog.control("links.archiveLittleArcsAfter").label, selection: Binding(
                    get: { model.littleArcArchiveLifetime }, set: { model.littleArcArchiveLifetime = $0 }
                )) {
                    ForEach(LittleArcArchiveLifetime.allCases) { Text($0.displayName).tag($0) }
                }
                .help("Little Arc windows left alone this long close, and their pages go to the archive.")
            } header: { Text("Little Arc") }
            Section {
                Text("Peek lets you preview a link without opening a new tab.")
                    .foregroundStyle(.secondary)
                Toggle(
                    SettingsCatalog.control("links.peekShiftClick").label,
                    isOn: Binding(get: { model.opensPeekOnShiftClick }, set: { model.opensPeekOnShiftClick = $0 })
                )
                Toggle(
                    SettingsCatalog.control("links.peekOtherSites").label,
                    isOn: Binding(get: { model.opensPeekForOtherSites }, set: { model.opensPeekForOtherSites = $0 })
                )
            } header: { Text("Peek") }
            Section {
                LabeledContent("Choose where links open inside Open Arc") {
                    CatalogButton(id: "links.airTrafficControl") { model.isAirTrafficControlShown = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $model.isAirTrafficControlShown, onDismiss: { model.airTrafficControlDidClose() }) {
            AirTrafficControlSheet(model: model.makeAirTrafficControlModel()) { model.isAirTrafficControlShown = false }
        }
    }
}

// MARK: - Shortcuts

/// Read-only list of every key Open Arc binds, grouped as in `02` and generated from the table the
/// menus bind from (`ShortcutCatalog`, B85). No custom shortcuts in v1 (plan Q17), so those
/// controls are disabled.
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
                CatalogButton(id: "shortcuts.basics") { model.startWithTheBasics() }
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

/// [03 §Icon] observed: a list of six app icons with a CURRENT ICON marker next to the chosen one.
/// Ours: six of our own color variants in a 3 × 2 grid (layout inferred); a click makes the icon
/// current, shows it in the Dock and keeps it across relaunches. B84.
struct IconPane: View {
    @ObservedObject var icons: AppIconSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the icon Open Arc shows in the Dock.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(AppIconChoice.allCases) { choice in
                    IconTile(choice: choice, image: icons.tileImage(choice), isCurrent: icons.current == choice) {
                        icons.select(choice)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

/// One icon in the Icon pane: the icon, its name, and CURRENT ICON under the chosen one.
struct IconTile: View {
    let choice: AppIconChoice
    let image: NSImage
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: SettingsTokens.iconTileSize, height: SettingsTokens.iconTileSize)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                Text(choice.displayName)
                Text("CURRENT ICON")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .opacity(isCurrent ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("openarc.icon.\(choice.rawValue)")
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
                    if id == "advanced.reorderHaptics" {
                        // [03 §Advanced] observed, on by default. Live since B68.
                        Toggle(SettingsCatalog.control(id).label, isOn: Binding(
                            get: { model.playsReorderHaptics }, set: { model.playsReorderHaptics = $0 }
                        ))
                    } else if id == "advanced.restoreWindows" {
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
                    } else if let keyPath = AdvancedBehaviorToggles.keyPath(id) {
                        // [03 §Advanced] observed, on by default. Live since B84.
                        AdvancedBehaviorToggle(id: id, settings: model.advancedBehavior, keyPath: keyPath)
                    } else {
                        PendingToggle(id: id)
                    }
                }
            }
            Section {
                CatalogButton(id: "advanced.moreSettings") { model.openMoreSettings() }
                // [03 §Advanced] observed button. Live since B47: forgets every profile's
                // translation decisions (never-translate sites and languages).
                CatalogButton(id: "advanced.resetTranslatePrompts") { Task { await model.resetTranslatedSitePrompts() } }
                // [03 §Advanced] observed button. Live since B84: our own JSON export.
                CatalogButton(id: "advanced.exportData") { Task { await model.exportData() } }
                if let status = model.exportStatus {
                    Text(status).font(Typography.settingsCaption.font).foregroundStyle(.secondary)
                }
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
        // Plan C19: a filter-list update shows its version without reopening Settings.
        .task { await model.followAdBlockingRulesetVersion() }
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

/// The Advanced switches backed by `AdvancedBehaviorSettings` (B84), by catalog id.
@MainActor
enum AdvancedBehaviorToggles {
    static func keyPath(_ id: String) -> ReferenceWritableKeyPath<AdvancedBehaviorSettings, Bool>? {
        switch id {
        case "advanced.soundEffects": return \.playsSoundEffects
        case "advanced.reorderHaptics": return \.playsReorderHaptics
        case "advanced.windowDragging": return \.allowsWindowDragFromPageTop
        default: return nil
        }
    }
}

/// A switch on the shared sound / haptic / window-drag settings (B84); every window follows.
struct AdvancedBehaviorToggle: View {
    let id: String
    @ObservedObject var settings: AdvancedBehaviorSettings
    let keyPath: ReferenceWritableKeyPath<AdvancedBehaviorSettings, Bool>

    var body: some View {
        Toggle(SettingsCatalog.control(id).label, isOn: Binding(
            get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }
        ))
    }
}

/// "Show full URL when Toolbar is enabled": the shared toolbar setting (B43).
struct WebToolbarFullURLToggle: View {
    @ObservedObject var settings: WebToolbarSettings

    var body: some View {
        Toggle(SettingsCatalog.control("advanced.showFullURL").label, isOn: $settings.showsFullURL)
    }
}
