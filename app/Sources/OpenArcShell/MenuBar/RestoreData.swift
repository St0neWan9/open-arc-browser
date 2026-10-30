import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
import OpenArcPersistence

// Help ▸ Restore Data (plan B117, decision Q18). [01 §Help] observed: the item exists, between
// Visit Help Center and Troubleshooting; what it does in Arc is not recorded. Ours restores the
// sidebar from one of the rolling local backups `WorkspaceStore` keeps (`WorkspaceBackups`). The
// sheet, its texts and the confirmation are our own design (inferred; no reference screenshot).

/// Help ▸ Restore Data. Enabled when the app's store has at least one backup and can take a
/// restore (not in an incognito window, which has no store, and not when the store is read-only).
struct RestoreDataMenuItem: View {
    /// Not observed (B103): the state is read from disk when the Help menu is rebuilt.
    let controller: WorkspaceController

    static func isEnabled(_ controller: WorkspaceController) -> Bool {
        !controller.isOffTheRecord && controller.dependencies.persistence?.canRestoreBackup == true
    }

    var body: some View {
        Button(RestoreDataLocalTokens.menuTitle) { RestoreDataPresenter.present(controller: controller) }
            .disabled(!Self.isEnabled(controller))
    }
}

/// Texts and sizes of the Restore Data sheet. Our own (inferred).
enum RestoreDataLocalTokens {
    /// [01 §Help] observed title.
    static let menuTitle = "Restore Data"
    static let title = "Restore Data"
    static let message = "Open Arc keeps a daily backup of your sidebar for the last 7 days. Choose one to restore."
    static let restore = "Restore"
    static let cancel = "Cancel"
    static let confirmTitle = "Replace your sidebar?"
    static let confirmMessage = "Your current Spaces, tabs and folders will be replaced by the backup. On your other Macs the change syncs like any edit."
    static let loading = "Reading backup…"
    static let unreadable = "Can't be read"
    static let failed = "The backup could not be restored."
    static let sheetWidth: Double = 440
    static let listHeight: Double = 200

    static func summary(_ summary: WorkspaceBackupSummary) -> String {
        "\(count(summary.spaceCount, "Space", "Spaces")) · \(count(summary.tabCount, "tab", "tabs"))"
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}

/// The sheet's state: the backups, the chosen one, and the restore.
@MainActor
final class RestoreDataModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var backup: WorkspaceBackup
        /// nil while reading; `.failure` when the file cannot be used.
        var summary: Result<WorkspaceBackupSummary, PersistenceError>?
        var id: URL { backup.id }
    }

    @Published private(set) var rows: [Row]
    @Published var selectedID: URL?
    @Published var isConfirming = false
    @Published private(set) var errorMessage: String?

    private weak var controller: WorkspaceController?
    /// Closes the sheet. Installed by the presenter.
    var onClose: (() -> Void)?

    init(controller: WorkspaceController) {
        self.controller = controller
        rows = (controller.dependencies.persistence?.backups() ?? []).map { Row(backup: $0, summary: nil) }
        selectedID = rows.first?.id
    }

    var selectedRow: Row? { rows.first { $0.id == selectedID } }

    /// Restore is possible for a backup that could be read.
    var canRestore: Bool {
        if case .success = selectedRow?.summary { return true }
        return false
    }

    /// Reads every backup off the main thread for its Space and tab counts.
    func loadSummaries() async {
        for index in rows.indices {
            let backup = rows[index].backup
            let summary = await Task.detached(priority: .userInitiated) {
                Result { try WorkspaceBackups.load(backup) }
                    .map(WorkspaceBackupSummary.init)
                    .mapError { ($0 as? PersistenceError) ?? .io(String(describing: $0)) }
            }.value
            guard index < rows.count, rows[index].backup == backup else { return }
            rows[index].summary = summary
        }
    }

    /// Restore: asks for confirmation first (it replaces the current sidebar).
    func requestRestore() {
        guard canRestore else { return }
        isConfirming = true
    }

    /// The confirmed restore: loads the chosen backup off the main thread, applies it and closes.
    func confirmRestore() async {
        isConfirming = false
        guard let backup = selectedRow?.backup, let controller else { return }
        let loaded = await Task.detached(priority: .userInitiated) { Result { try WorkspaceBackups.load(backup) } }.value
        do {
            try controller.restoreWorkspace(from: loaded.get())
            close()
        } catch {
            errorMessage = RestoreDataLocalTokens.failed
        }
    }

    func close() { onClose?() }
}

/// The sheet: one row per backup (date, Spaces and tabs), Cancel and Restore, then a confirmation.
struct RestoreDataSheet: View {
    @ObservedObject var model: RestoreDataModel
    typealias T = RestoreDataLocalTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T.title).font(Typography.dialogTitle.font)
            Text(T.message).font(Typography.settingsBody.font).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $model.selectedID) {
                ForEach(model.rows) { row in
                    HStack {
                        Text(row.backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(detail(row)).foregroundStyle(.secondary)
                    }
                    .font(Typography.settingsBody.font)
                    .tag(Optional(row.id))
                }
            }
            .frame(height: T.listHeight)
            if let message = model.errorMessage {
                Text(message).font(Typography.settingsBody.font).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(T.cancel) { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button(T.restore) { model.requestRestore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRestore)
            }
        }
        .padding(20)
        .frame(width: T.sheetWidth)
        .task { await model.loadSummaries() }
        .alert(T.confirmTitle, isPresented: $model.isConfirming) {
            Button(T.cancel, role: .cancel) {}
            Button(T.restore, role: .destructive) { Task { await model.confirmRestore() } }
        } message: {
            Text(T.confirmMessage)
        }
    }

    private func detail(_ row: RestoreDataModel.Row) -> String {
        switch row.summary {
        case nil: return T.loading
        case .success(let summary)?: return T.summary(summary)
        case .failure?: return T.unreadable
        }
    }
}

/// Shows the sheet on the key window (a floating panel when no window is open), like the import sheet.
@MainActor
enum RestoreDataPresenter {
    static func present(controller: WorkspaceController) {
        let model = RestoreDataModel(controller: controller)
        let hosting = NSHostingController(rootView: RestoreDataSheet(model: model))
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        if let host, host.attachedSheet == nil {
            let sheet = NSWindow(contentViewController: hosting)
            model.onClose = { [weak host, weak sheet] in
                guard let sheet else { return }
                host?.endSheet(sheet)
            }
            host.beginSheet(sheet)
        } else {
            let panel = NSPanel(contentViewController: hosting)
            panel.title = RestoreDataLocalTokens.title
            panel.styleMask = [.titled, .closable]
            model.onClose = { [weak panel] in panel?.close() }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension WorkspaceController {
    /// Replaces the sidebar with `backup`'s live records (`WorkspaceRestore`): records the backup
    /// has are written back as local edits stamped now, records it lacks are tombstoned, and
    /// records deleted since come back under new ids. The result is committed like any local
    /// change, so it is saved and every changed record reaches the sync store. Engine tabs of
    /// tabs the restore removes are closed; every window repairs its selection.
    func restoreWorkspace(from backup: WorkspaceState) throws {
        guard !isOffTheRecord, let store = dependencies.persistence, !store.isReadOnly else {
            throw PersistenceError.readOnly
        }
        let next = WorkspaceRestore.restored(current: workspace, backup: backup, now: now(), makeID: makeID)
        guard next != workspace else { return }
        let gone = liveTabEntries.map(\.id).filter { next.tabs[$0].map(\.meta.isTombstone) ?? true }
        commit(next, origin: nil)
        gone.forEach(closeLive)
    }
}
