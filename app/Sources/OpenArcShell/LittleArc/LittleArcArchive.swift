import Foundation
import OpenArcModel

// "Archive Little Arcs after" (plan B82).
//
// Spec: [03 §Links] observed: a dropdown "Archive Little Arcs after", default 6 hours.
// [03 §对复刻的含义] observed: tab auto-archive (default 12 hours) and the Little Arc archive
// (default 6 hours) are two independent timers.
//
// Decisions without evidence (inferred):
//   - The choices besides 6 hours (1 / 12 / 24 hours, 7 days) mirror "Archive tabs after".
//   - A window is idle from the last time it was used: opened, a page loaded or navigated, or the
//     window stopped being key. The key window is in use and never archived.
//   - An idle window with a page closes and its page becomes an archive item (reason
//     `.autoArchived`, the Space "Open in" names, so Restore brings it back there) through
//     `TreeOps.archivePage`; an idle compact window (no page) just closes.
//   - The timer checks every 5 minutes while a Little Arc window is open, so a window goes at most
//     5 minutes late; nothing ticks while none is open.

/// "Archive Little Arcs after" choices. Raw values are stored per device; never rename them.
public enum LittleArcArchiveLifetime: String, CaseIterable, Identifiable, Sendable {
    case oneHour, sixHours, twelveHours, twentyFourHours, sevenDays

    /// [03 §Links] observed default.
    public static let `default`: LittleArcArchiveLifetime = .sixHours

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oneHour: return "1 hour"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        }
    }

    public var interval: TimeInterval {
        let hour: TimeInterval = 60 * 60
        switch self {
        case .oneHour: return hour
        case .sixHours: return 6 * hour
        case .twelveHours: return 12 * hour
        case .twentyFourHours: return 24 * hour
        case .sevenDays: return 7 * 24 * hour
        }
    }
}

extension AppPreferences {
    static let littleArcArchiveLifetimeKey = "\(keyPrefix)links.archiveLittleArcsAfter"

    /// "Archive Little Arcs after". [03 §Links] observed, default 6 hours. Per device (an app-level
    /// Links setting, [03 §对复刻的含义] observed). An unknown stored value reads as the default.
    public var littleArcArchiveLifetime: LittleArcArchiveLifetime {
        get { stringValue(Self.littleArcArchiveLifetimeKey).flatMap(LittleArcArchiveLifetime.init(rawValue:)) ?? .default }
        set { setString(newValue.rawValue, Self.littleArcArchiveLifetimeKey) }
    }
}

extension SettingsModel {
    /// Settings ▸ Links ▸ Archive Little Arcs after (B82). Read on every check, so a change applies
    /// at the next one.
    public var littleArcArchiveLifetime: LittleArcArchiveLifetime {
        get { preferences.littleArcArchiveLifetime }
        set {
            objectWillChange.send()
            preferences.littleArcArchiveLifetime = newValue
            shell.controller.archiveIdleLittleArcs()
        }
    }
}

/// Open Little Arc windows of a controller and the timer that archives idle ones. One per
/// `WorkspaceController`.
@MainActor
final class LittleArcArchiveState {
    /// How often idle windows are looked for. inferred (see the file header).
    static let checkInterval: TimeInterval = 5 * 60

    private var models: [WeakLittleArc] = []
    private var scheduler: AutoArchiveScheduler?

    private struct WeakLittleArc {
        weak var model: LittleArcModel?
    }

    /// Little Arc windows that are still open.
    var openModels: [LittleArcModel] {
        models.removeAll { $0.model == nil || $0.model?.phase == .closed }
        return models.compactMap(\.model)
    }

    var isRunning: Bool { scheduler?.isRunning ?? false }

    /// Tracks `model`; the first open window starts the timer made by `makeScheduler`. The
    /// scheduler is stored before it starts, as its first run may close windows.
    func add(_ model: LittleArcModel, makeScheduler: () -> AutoArchiveScheduler) {
        guard !openModels.contains(where: { $0 === model }) else { return }
        models.append(WeakLittleArc(model: model))
        guard scheduler == nil else { return }
        let made = makeScheduler()
        scheduler = made
        made.start()
    }

    /// A window closed: the timer stops with the last one.
    func remove(_ model: LittleArcModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        if openModels.isEmpty { stop() }
    }

    func stop() {
        scheduler?.stop()
        scheduler = nil
    }
}

extension WorkspaceController {
    /// A Little Arc window opened on this controller: tracked for the idle archive, and the timer
    /// starts with the first one (its immediate first run finds nothing: a new window is not idle).
    func registerLittleArc(_ model: LittleArcModel) {
        guard !isStopped else { return }
        littleArcArchive.add(model) {
            AutoArchiveScheduler(interval: LittleArcArchiveState.checkInterval, ticker: autoArchiveTicker) { [weak self] in
                self?.archiveIdleLittleArcs()
            }
        }
    }

    func unregisterLittleArc(_ model: LittleArcModel) {
        littleArcArchive.remove(model)
    }

    /// Closes every Little Arc window idle for at least "Archive Little Arcs after" and archives
    /// its page. Returns the new archive item ids (one per window that had a page).
    @discardableResult
    func archiveIdleLittleArcs() -> [UUID] {
        let lifetime = dependencies.preferences.littleArcArchiveLifetime.interval
        let stamp = now()
        var archived: [UUID] = []
        for model in littleArcArchive.openModels where model.isIdle(at: stamp, lifetime: lifetime) {
            if let id = archiveLittleArcPage(model, now: stamp) { archived.append(id) }
            model.closeAfterArchive()
        }
        return archived
    }

    /// Archives `model`'s page as an archive item. nil when there is no page, the controller is
    /// incognito (nothing of it is kept), or the archive refused it.
    private func archiveLittleArcPage(_ model: LittleArcModel, now stamp: Date) -> UUID? {
        guard !isOffTheRecord, let page = model.archivablePage else { return nil }
        let id = makeID()
        let spaceID = model.targetSpaceID.flatMap { workspace.spaces[$0]?.meta.isTombstone == false ? $0 : nil }
        do {
            try mutate(origin: nil) {
                try TreeOps.archivePage($0, id: id, url: page.url, title: page.title, spaceID: spaceID, reason: .autoArchived, now: stamp)
            }
        } catch {
            return nil
        }
        return id
    }
}

extension LittleArcModel {
    /// Whether the window has been idle for `lifetime` at `date`. The key window never is.
    func isIdle(at date: Date, lifetime: TimeInterval) -> Bool {
        guard phase != .closed, !isKeyWindow else { return false }
        return date.timeIntervalSince(lastActiveAt) >= lifetime
    }

    /// URL and title the archive keeps; nil while compact.
    var archivablePage: (url: URL, title: String)? {
        guard phase == .expanded, let url = currentURL else { return nil }
        return (url, page.title.isEmpty ? (url.host ?? url.absoluteString) : page.title)
    }
}
