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
        // Our own pane toolbar (Arc's selection style, B100) above the pane; the window title
        // follows the pane ([03] observed).
        VStack(spacing: 0) {
            SettingsToolbar(selection: $model.selectedPane)
            SettingsPaneView(pane: model.selectedPane, model: model)
                .id(model.selectedPane)
        }
        .frame(width: SettingsTokens.windowWidth(for: model.selectedPane))
        .fixedSize(horizontal: false, vertical: true)
        // Always light (user decision, 2026-10-28; B100 capture: Arc's light Settings is white).
        .modifier(SettingsWindowChrome(title: model.selectedPane.title))
        .task { await model.observeSync() }
    }
}

/// Window size. Width [07 §6] observed (684; height follows the pane, 650 in Arc); the window
/// opens centered on the screen like Arc's ([07 §12] observed). B42.
enum SettingsTokens {
    static let windowWidth = CGFloat(Metrics.Settings.windowSize.width)
    /// The panes Arc shows 701 pt wide: Links ([06 §25] observed 701 × 650; [07 §6] "some pages").
    /// The others stay 684. The content column keeps its width and stays centered (inferred).
    static let widePanes: Set<SettingsPane> = [.links]

    /// The window width while `pane` is shown (F5-24).
    static func windowWidth(for pane: SettingsPane) -> CGFloat {
        widePanes.contains(pane) ? CGFloat(Metrics.Settings.wideWindowWidth) : windowWidth
    }
    /// Title bar plus toolbar above the pane: the system title bar and the 56 pt toolbar
    /// ([07 §6] observed; ours draws the toolbar itself since B100).
    static let chromeHeight = CGFloat(Metrics.Settings.titleBarHeight + Metrics.Settings.toolbarHeight)
    /// Pane height that makes the window 650 tall. [07 §6] observed.
    static let paneMinHeight = CGFloat(Metrics.Settings.windowSize.height) - chromeHeight
    /// Toggle rows repeat every 37 pt. [07 §6] observed.
    static let toggleRowPitch = Metrics.Settings.toggleRowPitch
    /// The profile list card. B100 capture, observed (205.5 × 478.5; the settings column 341).
    static let profileListWidth: CGFloat = 205.5
    /// Icon list: the app-icon tile, the radio button. B100 capture, observed (52, 22).
    static let iconTileSize: CGFloat = 52
    static let iconRadioSize: CGFloat = 22
    /// Icon list row pitch. B100 capture, observed (81).
    static let iconRowHeight: CGFloat = 80
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
        .frame(maxWidth: .infinity, minHeight: SettingsTokens.paneMinHeight, maxHeight: SettingsTokens.paneMinHeight,
               alignment: .top)
        .background(SettingsPalette.window.swiftUI)
    }
}

// MARK: - Building blocks

/// A catalog toggle with no backing feature: shows its default value, disabled.
struct PendingToggle: View {
    let id: String
    var tile: SettingsTile?

    var body: some View {
        let control = SettingsCatalog.control(id)
        if case .toggle(let value) = control.kind {
            SettingsToggleRow(label: control.label, isOn: .constant(value), tile: tile)
                .disabled(!control.isEnabled)
        }
    }
}

/// A catalog button; disabled unless `action` is given and the control is live. Arc's
/// borderless light-gray button (B100 capture, observed).
struct CatalogButton: View {
    let id: String
    var action: (() -> Void)?

    var body: some View {
        let control = SettingsCatalog.control(id)
        Button(control.label) { action?() }
            .buttonStyle(SettingsButtonStyle())
            .disabled(!control.isEnabled || action == nil)
    }
}

/// A catalog dropdown with no backing feature: shows only its default value, disabled.
struct PendingPicker: View {
    let id: String

    var body: some View {
        let control = SettingsCatalog.control(id)
        if case .picker(let value) = control.kind {
            SettingsControlRow(label: control.label) {
                SettingsPopupColumn { SettingsStaticPopup(title: value) }
            }
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
        SettingsCard {
            SettingsControlRow(label: model.statusText) {
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
/// "Last synced" line. Membership card, referral and account management are out of scope. Arc's
/// account tab was not captured for B100; it uses the same cards as the other panes.
struct AccountPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsColumn {
            DefaultBrowserBanner(model: model.defaultBrowser)
            SyncCardView(model: model, sync: model.sync)
        }
    }
}

/// The iCloud part of the account card. Observes the sync controller, so status changes redraw it.
struct SyncCardView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var sync: SidebarSyncController

    var body: some View {
        let card = sync.card
        VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
            SettingsCaption(text: "iCloud")
            SettingsCard {
                SettingsToggleRow(
                    label: SettingsCatalog.control("account.syncSidebar").label,
                    isOn: Binding(get: { sync.isEnabled }, set: { model.setSidebarSync($0) }),
                    // Our own wording: sync goes to the user's private iCloud database (CloudKit).
                    subtitle: "Your sidebar syncs through your private iCloud account."
                )
                .disabled(!card.isToggleEnabled)
                SettingsDivider()
                SettingsRow(height: SettingsLayout.controlRowHeight) {
                    // "Last synced" is relative; the timeline redraws it every minute.
                    TimelineView(.everyMinute) { _ in
                        Text(sync.card.statusLine)
                            .foregroundStyle(card.isWarning ? Color.orange : SettingsPalette.secondaryText.swiftUI)
                    }
                    Spacer(minLength: 12)
                    if let action = card.action {
                        Button(action.title) { model.performSyncAction(action) }
                            .buttonStyle(SettingsButtonStyle())
                    }
                }
                if sync.canDeleteServerData {
                    SettingsDivider()
                    SettingsRow(height: SettingsLayout.controlRowHeight) {
                        Spacer()
                        // D12: wipes our iCloud data after a confirmation.
                        Button(SyncCardState.DeleteServerData.buttonTitle, role: .destructive) { isConfirmingDelete = true }
                            .buttonStyle(SettingsButtonStyle())
                            .confirmationDialog(SyncCardState.DeleteServerData.confirmTitle, isPresented: $isConfirmingDelete) {
                                Button(SyncCardState.DeleteServerData.confirmButton, role: .destructive) { model.deleteICloudData() }
                            } message: {
                                Text(SyncCardState.DeleteServerData.confirmMessage)
                            }
                    }
                }
            }
        }
    }

    @State private var isConfirmingDelete = false
}

// MARK: - General

/// [03 §General] observed controls; B100 capture, observed layout: a switch card (automatic
/// updates with ⓘ, Warn before quitting) and a card with "Previews" and the Profile Settings hint,
/// each with a trailing button.
struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsColumn {
            SettingsCard {
                AutomaticUpdatesRow(model: model.updates)
                SettingsDivider()
                // [03 §General] observed, on by default. Live since B68.
                SettingsToggleRow(label: SettingsCatalog.control("general.warnBeforeQuitting").label, isOn: Binding(
                    get: { model.warnsBeforeQuitting }, set: { model.warnsBeforeQuitting = $0 }
                ))
            }
            SettingsCard {
                SettingsControlRow(label: "Previews") {
                    // Opens Links ▸ Peek (B84).
                    CatalogButton(id: "general.previewsSettings") { model.openPreviewsSettings() }
                }
                SettingsDivider()
                SettingsControlRow(label: Self.profileSettingsHint, maxLabelWidth: Self.hintWidth) {
                    CatalogButton(id: "general.profileSettings") { model.openProfileSettings() }
                }
            }
        }
    }

    /// Our wording of the hint ([03 §General] observed meaning: search engine, auto-archive and
    /// download location live in the Profile settings).
    static let profileSettingsHint = "Manage your default search engine, Auto-Archive, and downloads in Profile Settings."
    /// The hint wraps before the button. B100 capture, observed (≈ 330 pt).
    static let hintWidth: CGFloat = 330
}

/// "Automatically update Open Arc ⓘ": the D7 updater's automatic checks. B100 capture, observed
/// row (Arc's own update switch); disabled when this build cannot update itself.
struct AutomaticUpdatesRow: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        SettingsToggleRow(
            label: SettingsCatalog.control("general.automaticUpdates").label,
            isOn: Binding(get: { model.automaticallyChecksForUpdates }, set: { model.automaticallyChecksForUpdates = $0 }),
            info: model.unavailableReason ?? Self.info
        )
        .disabled(!model.isAvailable)
    }

    /// Our text for the ⓘ (inferred).
    static let info = "Open Arc checks for updates in the background and installs them when you quit."
}

// MARK: - Profiles

/// [03 §Profiles] observed controls; B100 capture, observed layout: the intro paragraph with an
/// inline "Learn more." link, a bordered profile list on the left (header, rows, a + − bar), the
/// edited profile's cards on the right.
struct ProfilesPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var sidebar: SidebarViewModel

    init(model: SettingsModel) {
        self.model = model
        self.sidebar = model.shell.sidebar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro
            HStack(alignment: .top, spacing: 10) {
                ProfileListCard(model: model)
                    .frame(width: SettingsTokens.profileListWidth)
                profileSettings
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsLayout.columnWidth, alignment: .topLeading)
        .padding(.top, SettingsLayout.paneTopPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
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

    /// [03 §Profiles] observed text and "Learn more"; B100 capture: body color, the link inline.
    private var intro: some View {
        (Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces. ")
            + Text("[Learn more.](\(Self.learnMoreLink))").underline())
            .font(SettingsFonts.body)
            .foregroundStyle(SettingsPalette.bodyText.swiftUI)
            .tint(SettingsPalette.link.swiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.absoluteString == Self.learnMoreLink else { return .systemAction }
                model.openProfilesHelp()
                return .handled
            })
    }

    /// The inline link's target; the model opens our help page instead (B83).
    static let learnMoreLink = "openarc-settings:profiles-help"

    private var profileSettings: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
                SettingsCard {
                    SettingsControlRow(label: SettingsCatalog.control("profiles.searchEngine").label) {
                        SettingsPopupColumn {
                            SettingsPopup(
                                label: SettingsCatalog.control("profiles.searchEngine").label,
                                selection: Binding(get: { model.searchEngine }, set: { model.searchEngine = $0 }),
                                options: SearchEngine.allCases.map { SettingsOption(value: $0, title: $0.displayName) }
                            )
                        }
                    }
                    SettingsDivider()
                    SettingsControlRow(label: "Manage search") {
                        CatalogButton(id: "profiles.searchSettings") { model.openEnginePage(.searchSettings) }
                            .disabled(!model.canOpenEditedProfilePages)
                    }
                    SettingsDivider()
                    SettingsToggleRow(
                        label: SettingsCatalog.control("profiles.searchSuggestions").label,
                        isOn: Binding(get: { model.includesSearchSuggestions }, set: { model.includesSearchSuggestions = $0 })
                    )
                }
                SettingsCard {
                    // ⓘ: [03 §Profiles] observed; its text was not recorded, ours (inferred).
                    SettingsControlRow(label: SettingsCatalog.control("profiles.archiveTabsAfter").label,
                                       info: "Unpinned tabs in Today are archived after they have been idle this long.") {
                        SettingsPopupColumn {
                            SettingsPopup(
                                label: SettingsCatalog.control("profiles.archiveTabsAfter").label,
                                selection: Binding(get: { model.archiveLifetime }, set: { model.archiveLifetime = $0 }),
                                options: ArchiveLifetime.allCases.map { SettingsOption(value: $0, title: SettingsDefaults.title($0.displayName, isDefault: $0 == .default)) }
                            )
                        }
                    }
                    SettingsDivider()
                    PendingPicker(id: "profiles.newDocuments")
                    SettingsDivider()
                    DownloadLocationPicker(model: model)
                }
                SettingsCaption(text: "Your Data and Settings")
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Self.dataRows, id: \.self) { page in
                            DataRow(id: page.controlID, tile: Self.tile(page)) { model.openEnginePage(page) }
                                .disabled(!model.canOpenEditedProfilePages)
                        }
                        DataRow(id: "profiles.clearBrowsingData", tile: Self.clearDataTile) { model.requestClearBrowsingData() }
                    }
                    .padding(.vertical, SettingsLayout.dataCardVerticalPadding)
                }
                if !model.canOpenEditedProfilePages {
                    // A page opens in a tab of a Space that uses this Profile (inferred).
                    Text("Assign this Profile to a Space to manage its data.")
                        .font(SettingsFonts.caption)
                        .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                        .padding(.leading, SettingsLayout.rowInset)
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// [03 §Profiles] observed order: Privacy and Security · Passwords · Credit Cards ·
    /// Notifications · Autofill, then Clear Browsing Data.
    static let dataRows: [ProfileEnginePage] = [.privacy, .passwords, .creditCards, .notifications, .autofill]

    /// Icon tile of a data row: colors B100 capture, observed (Autofill not shown there: ours);
    /// SF Symbols our own choice.
    static func tile(_ page: ProfileEnginePage) -> SettingsTile {
        switch page {
        case .privacy: return SettingsTile(symbol: "lock.fill", color: SettingsTile.dataBlue)
        case .passwords: return SettingsTile(symbol: "key.fill", color: SettingsTile.dataGreen)
        case .creditCards: return SettingsTile(symbol: "creditcard.fill", color: SettingsTile.dataYellow)
        case .notifications: return SettingsTile(symbol: "bell.fill", color: SettingsTile.dataOrange)
        case .autofill: return SettingsTile(symbol: "text.cursor", color: SettingsTile.dataTeal)
        case .searchSettings, .allSettings: return SettingsTile(symbol: "gearshape.fill", color: SettingsTile.gray)
        }
    }

    static let clearDataTile = SettingsTile(symbol: "trash.fill", color: SettingsTile.dataRed)
}

/// "(default)" after the default choice of a popup. B100 capture, observed ("12 hours
/// (default)", "6 hours (default)").
enum SettingsDefaults {
    static func title(_ title: String, isDefault: Bool) -> String {
        isDefault ? "\(title) (default)" : title
    }
}

/// The profile list: a bordered card with the "Your Profiles" header, one light-gray rounded row
/// per profile ("Default · 8 Spaces"), and a bottom bar with + − and a rename button separated by
/// thin lines. [03 §Profiles], [06 §16.3] observed behavior; B100 capture, observed look.
struct ProfileListCard: View {
    @ObservedObject var model: SettingsModel
    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        SettingsCard(style: .list) {
            Text("Your Profiles")
                .font(SettingsFonts.listHeader)
                .foregroundStyle(SettingsPalette.listHeader.swiftUI)
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                .padding(.leading, 17)
            listLine
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(model.profileRows) { row in
                        ProfileListRow(row: row, isSelected: row.id == model.editedProfileID, renaming: $renaming, draftName: $draftName) {
                            model.selectedProfileID = row.id
                        } commitRename: {
                            model.renameProfile(row.id, to: draftName)
                            renaming = nil
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            if let reason = model.profileDeletionBlockedReason {
                Text(reason)
                    .font(SettingsFonts.caption)
                    .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            listLine
            bottomBar
        }
    }

    private var listLine: some View {
        Rectangle().fill(SettingsPalette.cardBorder.swiftUI).frame(height: 1)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("plus", help: SettingsCatalog.control("profiles.add").label) { model.addProfile() }
            barSeparator
            // Enabled only when the edited profile can be deleted; otherwise the reason shows.
            // [03 §Profiles] observed: "The Default Profile cannot be deleted."
            barButton("minus", help: model.profileDeletionBlockedReason ?? SettingsCatalog.control("profiles.remove").label) {
                model.requestDeleteEditedProfile()
            }
            .disabled(!model.canDeleteEditedProfile)
            barSeparator
            // Rename the edited profile (our action for the bar's third button; B100 capture,
            // observed glyph, its action inferred).
            barButton("square.and.pencil", help: "Rename Profile") {
                guard let id = model.editedProfileID else { return }
                draftName = model.profileRows.first { $0.id == id }?.name ?? ""
                renaming = id
            }
            Spacer()
        }
        .frame(height: 32)
    }

    private var barSeparator: some View {
        Rectangle().fill(SettingsPalette.cardBorder.swiftUI).frame(width: 1, height: 24)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(ProfileBarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ProfileBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProfileBarButtonBody(configuration: configuration)
    }
}

private struct ProfileBarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle((isEnabled ? SettingsPalette.bodyText : SettingsPalette.disabledText).swiftUI)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// One profile: name on the left, "N Spaces" on the right, on a light-gray rounded fill when
/// selected. B100 capture, observed (row 173 × 32, corner ≈ 8).
struct ProfileListRow: View {
    let row: SettingsProfileRow
    let isSelected: Bool
    @Binding var renaming: UUID?
    @Binding var draftName: String
    let select: () -> Void
    let commitRename: () -> Void

    static let height: CGFloat = 32

    var body: some View {
        HStack {
            if renaming == row.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = nil }
            } else {
                Text(row.name).foregroundStyle(SettingsPalette.bodyText.swiftUI)
            }
            Spacer(minLength: 8)
            Text(row.detail)
                .font(SettingsFonts.body)
                .foregroundStyle(SettingsPalette.secondaryText.swiftUI.opacity(0.95))
        }
        .font(SettingsFonts.body)
        .padding(.horizontal, 7)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? SettingsPalette.profileRowFill.swiftUI : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A "Your Data and Settings" row: colored icon tile, label and a → arrow; the whole row is the
/// button. [03 §Profiles] observed: each item is a row with an arrow; B100 capture, observed look
/// (no dividers between these rows).
struct DataRow: View {
    let id: String
    var tile: SettingsTile?
    let action: () -> Void

    var body: some View {
        let control = SettingsCatalog.control(id)
        Button(action: action) {
            HStack(spacing: SettingsLayout.tileLabelSpacing) {
                if let tile { SettingsTileView(tile: tile, size: SettingsLayout.dataTileSize) }
                Text(control.label).foregroundStyle(SettingsPalette.bodyText.swiftUI)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.rowArrow.swiftUI)
            }
            .font(SettingsFonts.body)
            .padding(.horizontal, SettingsLayout.rowInset)
            .frame(height: SettingsLayout.dataRowHeight)
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
        let label = SettingsCatalog.control("profiles.downloadLocation").label
        SettingsControlRow(label: label) {
            SettingsPopupColumn {
                SettingsPopup(
                    label: label,
                    selection: Binding(
                        get: { DownloadLocationChoice.folder(model.downloadDirectory.standardizedFileURL) },
                        set: { choice in Task { await model.chooseDownloadLocation(choice) } }
                    ),
                    options: model.downloadLocationChoices.map { choice in
                        switch choice {
                        case .folder(let url): return SettingsOption(value: choice, title: SettingsModel.displayName(of: url))
                        case .other: return SettingsOption(value: choice, title: "Other…")
                        }
                    },
                    icon: { choice in
                        if case .folder(let url) = choice { return NSWorkspace.shared.icon(forFile: url.path) }
                        return nil
                    }
                )
                .help(model.downloadDirectory.path)
            }
        }
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

/// [03 §Links] observed controls; B100 capture, observed layout: a colored header band, then for
/// Little Arc and Peek a body paragraph above a switch card, a full-width hairline between the
/// groups, and Air Traffic Control in its own card.
struct LinksPane: View {
    @ObservedObject var model: SettingsModel

    /// The italic note under "Open links to other sites in Peek", lower-case "tabs". [06 §25.1]
    /// observed (F5-25).
    static let peekOtherSitesNote = "Note: This only affects Favorites and Pinned tabs"

    var body: some View {
        SettingsScrollingPane {
            VStack(spacing: 0) {
                LinksHeaderBand()
                VStack(alignment: .leading, spacing: 0) {
                    SettingsParagraph(text: "Little Arc is a smaller, simpler Open Arc window. It’s perfect for quick lookups and reading links your friends send you.")
                        .padding(.bottom, 24)
                    SettingsCard {
                        SettingsToggleRow(
                            label: SettingsCatalog.control("links.littleArcHotKey").label,
                            isOn: Binding(get: { model.opensLittleArcWithGlobalHotKey }, set: { model.opensLittleArcWithGlobalHotKey = $0 })
                        )
                        SettingsDivider()
                        SettingsToggleRow(
                            label: SettingsCatalog.control("links.littleArcModifierClick").label,
                            isOn: Binding(get: { model.opensLittleArcOnOptionCommandClick }, set: { model.opensLittleArcOnOptionCommandClick = $0 })
                        )
                        SettingsDivider()
                        SettingsToggleRow(
                            label: SettingsCatalog.control("links.littleArcExternal").label,
                            isOn: Binding(get: { model.opensExternalLinksInLittleArc }, set: { model.opensExternalLinksInLittleArc = $0 })
                        )
                        SettingsDivider()
                        SettingsControlRow(label: SettingsCatalog.control("links.archiveLittleArcsAfter").label,
                                           info: "Little Arc windows left alone this long close, and their pages go to the archive.") {
                            SettingsPopupColumn {
                                SettingsPopup(
                                    label: SettingsCatalog.control("links.archiveLittleArcsAfter").label,
                                    selection: Binding(get: { model.littleArcArchiveLifetime }, set: { model.littleArcArchiveLifetime = $0 }),
                                    options: LittleArcArchiveLifetime.allCases.map {
                                        SettingsOption(value: $0, title: SettingsDefaults.title($0.displayName, isDefault: $0 == .default))
                                    }
                                )
                            }
                        }
                    }
                    LinksGroupHairline()
                    SettingsParagraph(text: "Peek is a way to preview a link without opening a new tab. It’s perfect for quickly looking at a link from an email, a news article, or a post.")
                        .padding(.bottom, 24)
                    SettingsCard {
                        SettingsToggleRow(
                            label: SettingsCatalog.control("links.peekShiftClick").label,
                            isOn: Binding(get: { model.opensPeekOnShiftClick }, set: { model.opensPeekOnShiftClick = $0 })
                        )
                        SettingsDivider()
                        SettingsToggleRow(
                            label: SettingsCatalog.control("links.peekOtherSites").label,
                            isOn: Binding(get: { model.opensPeekForOtherSites }, set: { model.opensPeekForOtherSites = $0 }),
                            subtitle: LinksPane.peekOtherSitesNote,
                            subtitleIsNote: true
                        )
                    }
                    LinksGroupHairline()
                    SettingsCard {
                        SettingsControlRow(label: "Choose where links open inside Open Arc.",
                                           info: "Air Traffic Control sends links from other apps to the Space you pick, by site.") {
                            CatalogButton(id: "links.airTrafficControl") { model.isAirTrafficControlShown = true }
                        }
                    }
                }
                .frame(width: SettingsLayout.columnWidth)
                .padding(.top, 30)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $model.isAirTrafficControlShown, onDismiss: { model.airTrafficControlDidClose() }) {
            AirTrafficControlSheet(model: model.makeAirTrafficControlModel()) { model.isAirTrafficControlShown = false }
        }
    }
}

/// Full-width hairline between the Little Arc and Peek groups. B100 capture, observed (column
/// wide, #EEEEEE, 25 pt above and below).
struct LinksGroupHairline: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.divider.swiftUI)
            .frame(height: 1)
            .padding(.vertical, 25)
    }
}

/// The band at the top of the Links pane: a soft coral block with a scalloped bottom edge and a
/// stylized small window. Ours: Arc's band carries its own illustration (not copied); the band's
/// height and color are B100 capture, observed (134.5 pt, #F4AEAC).
struct LinksHeaderBand: View {
    static let height: CGFloat = 134.5
    static let color = RGBAColor(hex: 0xF4AEAC)

    var body: some View {
        ZStack(alignment: .bottom) {
            ScallopedBand(scallop: 6)
                .fill(Self.color.swiftUI)
            MiniWindowSketch()
                .frame(width: 300, height: 74)
                .offset(y: -10)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// A rectangle whose bottom edge is a row of shallow arcs.
struct ScallopedBand: Shape {
    var scallop: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - scallop))
        let width = scallop * 4
        var x = rect.maxX
        while x > rect.minX {
            let next = max(rect.minX, x - width)
            path.addQuadCurve(to: CGPoint(x: next, y: rect.maxY - scallop),
                              control: CGPoint(x: (x + next) / 2, y: rect.maxY + scallop * 0.4))
            x = next
        }
        path.closeSubpath()
        return path
    }
}

/// Our sketch of a small floating window: a title strip with three dots and an address pill.
struct MiniWindowSketch: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.7)).frame(width: 6, height: 6) }
                Capsule().fill(Color.white.opacity(0.75)).frame(height: 12).padding(.leading, 10)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            Rectangle().fill(Color.white.opacity(0.35))
        }
        .background(Color.white.opacity(0.4))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
    }
}

// MARK: - Shortcuts

/// Read-only list of every key Open Arc binds, grouped as in `02` and generated from the table the
/// menus bind from (`ShortcutCatalog`, B85). No custom shortcuts in v1 (plan Q17), so those
/// controls are disabled. B100 capture, observed layout: a centered "Start with the basics" pill
/// on top, the search field and list in a bordered card on the left, the custom-shortcuts column
/// on the right with Reset All Shortcuts and a ⋯ button at the bottom.
struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 30) {
            basicsPill
            HStack(alignment: .top, spacing: 15) {
                shortcutList.frame(width: Self.listWidth)
                sideColumn
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsLayout.columnWidth)
        .padding(.top, SettingsLayout.paneTopPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// List card width. B100 capture, observed (341).
    static let listWidth: CGFloat = 341

    /// "Start with the basics | ⌘ Learn the Essential Shortcuts": a white pill with a soft
    /// shadow, the button a gray rounded box. B100 capture, observed (380 × 36); [02 §其他]
    /// observed target.
    private var basicsPill: some View {
        HStack(spacing: 8) {
            Text(SettingsCatalog.control("shortcuts.basics").label)
                .foregroundStyle(SettingsPalette.bodyText.swiftUI)
            Button {
                model.startWithTheBasics()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "command.circle.fill")
                    Text("Learn the Essential Shortcuts")
                }
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .font(SettingsFonts.body)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        )
        .disabled(!SettingsCatalog.control("shortcuts.basics").isEnabled)
    }

    private var shortcutList: some View {
        SettingsCard(style: .list) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                TextField(SettingsCatalog.control("shortcuts.search").label, text: $model.shortcutQuery)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .frame(height: 40)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.shortcutGroups) { group in
                        Section {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { SettingsDivider(leadingInset: 24).padding(.trailing, 14) }
                                HStack {
                                    Text(entry.action)
                                        .foregroundStyle(SettingsPalette.strongText.swiftUI)
                                    Spacer(minLength: 8)
                                    SettingsKeyCap(keys: entry.keys)
                                }
                                .font(SettingsFonts.body)
                                .padding(.leading, 24)
                                .padding(.trailing, 24)
                                .frame(height: Self.rowHeight)
                            }
                        } header: {
                            VStack(spacing: 0) {
                                Rectangle().fill(SettingsPalette.cardBorder.swiftUI).frame(height: 1)
                                Text(group.title)
                                    .font(SettingsFonts.listHeader)
                                    .foregroundStyle(SettingsPalette.listHeader.swiftUI)
                                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                                    .padding(.leading, 16)
                                Rectangle().fill(SettingsPalette.cardBorder.swiftUI).frame(height: 1)
                            }
                            .background(Color.white)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Row pitch. B100 capture, observed (48).
    static let rowHeight: CGFloat = 47

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeyCapsArt()
                .padding(.bottom, 32)
            Text(SettingsCatalog.control("shortcuts.custom").label)
                .font(SettingsFonts.sideTitle)
                .foregroundStyle(SettingsPalette.strongText.swiftUI)
                .padding(.bottom, 10)
            // Our wording: v1 has no custom shortcuts (plan Q17).
            Text("Changing shortcuts, and choosing whether Open Arc or a website gets a key first, comes after v1.")
                .font(SettingsFonts.body)
                .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 6) {
                CatalogButton(id: "shortcuts.reset")
                Menu {
                    Picker(SettingsCatalog.control("shortcuts.priority").label, selection: .constant(0)) {
                        Text("Website first, except Open Arc's core keys").tag(0)
                    }
                    .disabled(true)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(EllipsisButtonStyle())
                .fixedSize()
                .disabled(!SettingsCatalog.control("shortcuts.priority").isEnabled)
                .accessibilityLabel(SettingsCatalog.control("shortcuts.priority").label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The round "⋯" button beside Reset All Shortcuts. B100 capture, observed (24 pt circle, gray rim).
private struct EllipsisButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(SettingsPalette.strongText.swiftUI)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(SettingsPalette.listCardBorder.swiftUI, lineWidth: 1))
            .contentShape(Circle())
    }
}

/// Our drawing of two big key caps (⌘ and a smiling key) above Custom Shortcuts. Ours; size from
/// the B100 capture (two 65 pt caps).
struct KeyCapsArt: View {
    var body: some View {
        HStack(spacing: 4) {
            cap { Image(systemName: "command").font(.system(size: 26, weight: .semibold)) }
            cap {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Capsule().frame(width: 3, height: 10)
                        Capsule().frame(width: 3, height: 10)
                    }
                    Capsule().frame(width: 22, height: 3)
                }
            }
        }
        .foregroundStyle(Color(white: 0.45))
        .accessibilityHidden(true)
    }

    private func cap(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.63))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.89)], startPoint: .top, endPoint: .bottom))
                .padding(EdgeInsets(top: 3, leading: 4, bottom: 9, trailing: 4))
            content().offset(y: -3)
        }
        .frame(width: 65, height: 65)
    }
}

// MARK: - Icon

/// [03 §Icon] observed: a list of six app icons with a CURRENT ICON marker next to the chosen one.
/// B100 capture, observed layout: one bordered card, a row per icon (radio button, rounded icon
/// tile, bold name, "CURRENT ICON" under the current one), hairlines between rows. Our own six
/// color variants (icon art is ours); a click makes the icon current, shows it in the Dock and
/// keeps it across relaunches. B84.
struct IconPane: View {
    @ObservedObject var icons: AppIconSettings

    var body: some View {
        SettingsColumn {
            SettingsCard(style: .list) {
                VStack(spacing: 0) {
                    ForEach(Array(AppIconChoice.allCases.enumerated()), id: \.element) { index, choice in
                        if index > 0 { SettingsDivider(leadingInset: 40).padding(.trailing, 30) }
                        IconTile(choice: choice, image: icons.tileImage(choice), isCurrent: icons.current == choice) {
                            icons.select(choice)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

/// One icon row: radio button, the icon, its name, and CURRENT ICON under the chosen one.
struct IconTile: View {
    let choice: AppIconChoice
    let image: NSImage
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                RadioMark(isOn: isCurrent)
                    .padding(.leading, 16)
                    .padding(.trailing, 26)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: SettingsTokens.iconTileSize, height: SettingsTokens.iconTileSize)
                    .padding(.trailing, 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.displayName)
                        .font(SettingsFonts.iconName)
                        .foregroundStyle(SettingsPalette.strongText.swiftUI)
                    if isCurrent {
                        Text("CURRENT ICON")
                            .font(SettingsFonts.currentIcon)
                            .foregroundStyle(SettingsPalette.currentIconCaption.swiftUI)
                    }
                }
                Spacer()
            }
            .frame(height: SettingsTokens.iconRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("openarc.icon.\(choice.rawValue)")
    }
}

/// A radio button: a blue disc with a white ring when on, a gray ring when off. B100 capture,
/// observed (22 pt).
struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(SettingsPalette.radioSelected.swiftUI)
                Circle().strokeBorder(Color.white, lineWidth: 2).padding(1.5)
            } else {
                Circle().strokeBorder(SettingsPalette.radioRing.swiftUI, lineWidth: 1)
            }
        }
        .frame(width: SettingsTokens.iconRadioSize, height: SettingsTokens.iconRadioSize)
    }
}

// MARK: - Advanced

/// [03 §Advanced] observed switches and buttons; B100 capture, observed layout: three cards of
/// tiled rows (sound and haptics; windows and pages; video, theme data and Boosts), then More
/// Settings… and Reset Translated-site Prompts on the left and Export Data on the right. Our own
/// rows (ad blocking, Check for Updates, crash reports) follow in one compact card in the same
/// style (B120).
struct AdvancedPane: View {
    @ObservedObject var model: SettingsModel

    static let toggleIDs = [
        "advanced.soundEffects", "advanced.reorderHaptics", "advanced.restoreWindows",
        "advanced.windowDragging", "advanced.showFullURL", "advanced.pictureInPicture",
        "advanced.themeData", "advanced.boosts",
    ]

    /// The three cards, as Arc groups them. B100 capture, observed.
    static let cards: [[String]] = [
        ["advanced.soundEffects", "advanced.reorderHaptics"],
        ["advanced.restoreWindows", "advanced.windowDragging", "advanced.showFullURL"],
        ["advanced.pictureInPicture", "advanced.themeData", "advanced.boosts"],
    ]

    /// Tile of each row: colors B100 capture, observed (blue, green, red, purple per group);
    /// SF Symbols our own choice.
    static func tile(_ id: String) -> SettingsTile {
        switch id {
        case "advanced.soundEffects": return SettingsTile(symbol: "speaker.wave.2.fill", color: SettingsTile.blue)
        case "advanced.reorderHaptics": return SettingsTile(symbol: "hand.point.up.fill", color: SettingsTile.blue)
        case "advanced.restoreWindows": return SettingsTile(symbol: "macwindow", color: SettingsTile.green)
        case "advanced.windowDragging": return SettingsTile(symbol: "rectangle.topthird.inset.filled", color: SettingsTile.green)
        case "advanced.showFullURL": return SettingsTile(symbol: "ellipsis.rectangle.fill", color: SettingsTile.red)
        case "advanced.pictureInPicture": return SettingsTile(symbol: "pip.fill", color: SettingsTile.purple)
        case "advanced.themeData": return SettingsTile(symbol: "paintpalette.fill", color: SettingsTile.purple)
        case "advanced.boosts": return SettingsTile(symbol: "paintbrush.pointed.fill", color: SettingsTile.purple)
        case "advanced.adBlocking": return SettingsTile(symbol: "hand.raised.fill", color: SettingsTile.gray)
        case "advanced.showCrashReports": return SettingsTile(symbol: "doc.text.magnifyingglass", color: SettingsTile.gray)
        case "advanced.checkForUpdates": return SettingsTile(symbol: "arrow.triangle.2.circlepath", color: SettingsTile.gray)
        default: return SettingsTile(symbol: "arrow.triangle.2.circlepath", color: SettingsTile.gray)
        }
    }

    var body: some View {
        SettingsScrollingPane {
            SettingsColumn {
                ForEach(Self.cards, id: \.self) { ids in
                    SettingsCard {
                        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                            if index > 0 { SettingsDivider() }
                            toggleRow(id)
                        }
                    }
                }
                HStack(spacing: 8) {
                    CatalogButton(id: "advanced.moreSettings") { model.openMoreSettings() }
                    // [03 §Advanced] observed button. Live since B47: forgets every profile's
                    // translation decisions (never-translate sites and languages).
                    CatalogButton(id: "advanced.resetTranslatePrompts") { Task { await model.resetTranslatedSitePrompts() } }
                    Spacer()
                    // [03 §Advanced] observed button. Live since B84: our own JSON export.
                    CatalogButton(id: "advanced.exportData") { Task { await model.exportData() } }
                }
                .padding(.top, 2)
                if let status = model.exportStatus {
                    Text(status)
                        .font(SettingsFonts.caption)
                        .foregroundStyle(SettingsPalette.secondaryText.swiftUI)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ourRows.padding(.top, 12)
            }
        }
        .task { await model.loadAdBlocking() }
        // Plan C19: a filter-list update shows its version without reopening Settings.
        .task { await model.followAdBlockingRulesetVersion() }
    }

    @ViewBuilder
    private func toggleRow(_ id: String) -> some View {
        let label = SettingsCatalog.control(id).label
        let tile = Self.tile(id)
        switch id {
        case "advanced.reorderHaptics":
            // [03 §Advanced] observed, on by default. Live since B68.
            SettingsToggleRow(label: label, isOn: Binding(
                get: { model.playsReorderHaptics }, set: { model.playsReorderHaptics = $0 }
            ), tile: tile)
        case "advanced.restoreWindows":
            // [03 §Advanced] observed, off by default. Live since B14.
            SettingsToggleRow(label: label, isOn: Binding(
                get: { model.restoresWindows }, set: { model.restoresWindows = $0 }
            ), tile: tile)
        case "advanced.showFullURL":
            // [03 §Advanced] observed, off by default; [06 §17.2] the toolbar shows the address
            // without its scheme. Live since B43; every window follows.
            WebToolbarFullURLToggle(settings: model.shell.webToolbar, tile: tile)
        case "advanced.pictureInPicture":
            // [03 §Advanced] observed, on by default. Live since C15.
            SettingsToggleRow(label: label, isOn: Binding(
                get: { model.entersPictureInPictureOnLeavingVideoTab },
                set: { model.entersPictureInPictureOnLeavingVideoTab = $0 }
            ), tile: tile)
        default:
            if let keyPath = AdvancedBehaviorToggles.keyPath(id) {
                // [03 §Advanced] observed, on by default. Live since B84.
                AdvancedBehaviorToggle(id: id, settings: model.advancedBehavior, keyPath: keyPath, tile: tile)
            } else {
                PendingToggle(id: id, tile: tile)
            }
        }
    }

    /// Rows of our one extra card after Arc's groups and the button row (B120), in order. Not in
    /// [03 §Advanced]: ad blocking (plan C16; shown only with a filter ruleset), Check for Updates
    /// (plan D7; its automatic switch is General's "Automatically update Open Arc"), crash reports
    /// (plan Q8). Compact: one row each, the details behind ⓘ.
    static let extraRowIDs = ["advanced.adBlocking", "advanced.checkForUpdates", "advanced.showCrashReports"]

    /// Our extra card, drawn the same way as Arc's (B100 style).
    @ViewBuilder
    private var ourRows: some View {
        SettingsCard {
            // Plan C16: the engine's ad blocker; hidden when the engine has no filter ruleset.
            if let version = model.adBlockingRulesetVersion {
                SettingsToggleRow(
                    label: SettingsCatalog.control("advanced.adBlocking").label,
                    isOn: Binding(get: { model.isAdBlockingOn }, set: { isOn in Task { await model.setAdBlocking(isOn) } }),
                    info: Self.adBlockingInfo(version: version),
                    tile: Self.tile("advanced.adBlocking")
                )
                SettingsDivider()
            }
            // Plan D7: the manual check. The automatic switch is General's (B100); not repeated here.
            AdvancedUpdateRow(model: model.updates, tile: Self.tile("advanced.checkForUpdates"))
            SettingsDivider()
            // Plan decision Q8: stored locally only, never uploaded.
            SettingsControlRow(label: Self.crashReportsLabel, info: Self.crashReportsInfo,
                               tile: Self.tile("advanced.showCrashReports")) {
                CatalogButton(id: "advanced.showCrashReports") { model.showCrashReports() }
            }
        }
    }

    /// Labels and ⓘ texts of the extra card (our wording, inferred).
    static func adBlockingInfo(version: String) -> String {
        "EasyList and EasyPrivacy (\(version)). Sites can be allowed one by one in the site controls."
    }
    static let crashReportsLabel = "Crash Reports"
    static let crashReportsInfo = "Stored on this Mac only, never sent anywhere."
}

/// Software Update row of Advanced's extra card: Check for Updates… (plan D7). The automatic-update
/// switch is General's "Automatically update Open Arc" (B100 capture, observed); B120 dropped the
/// second switch this pane had.
struct AdvancedUpdateRow: View {
    @ObservedObject var model: UpdatesModel
    let tile: SettingsTile

    var body: some View {
        SettingsControlRow(label: UpdateStrings.sectionTitle, info: model.unavailableReason, tile: tile) {
            Button(UpdateStrings.checkForUpdates) { model.checkForUpdates() }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!model.isCheckEnabled)
        }
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
    var tile: SettingsTile?

    var body: some View {
        SettingsToggleRow(label: SettingsCatalog.control(id).label, isOn: Binding(
            get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }
        ), tile: tile)
    }
}

/// "Show full URL when Toolbar is enabled": the shared toolbar setting (B43). Its subtitle says
/// Copy URL as Quote (⌃⇧⌘C) still copies the address with the full URL off ([02 §复制链接]
/// observed note in Settings; [03 §外观] the red "toolbar, quote" tile; F5-26). Wording ours.
struct WebToolbarFullURLToggle: View {
    @ObservedObject var settings: WebToolbarSettings
    var tile: SettingsTile?

    static let quoteNote = "With this off, Copy URL as Quote (⌃⇧⌘C) still copies the page’s address as a quote."

    var body: some View {
        SettingsToggleRow(label: SettingsCatalog.control("advanced.showFullURL").label, isOn: $settings.showsFullURL,
                          subtitle: Self.quoteNote, tile: tile)
    }
}
