import Foundation
import OpenArcModel

/// One choice of the "Open in" and "Default" menus. [06 §25.2] observed: every Space in sidebar
/// order (a Space of a non-Default profile shows the profile in parentheses), then "Most Recent
/// Space", then "Little Arc".
public struct AirTrafficTargetOption: Identifiable, Hashable, Sendable {
    public let target: AirTrafficTarget
    public let title: String

    public var id: AirTrafficTarget { target }
}

/// State and actions of the Air Traffic Control sheet (Settings ▸ Links). Every change is written
/// to the preferences at once: there is no Save button. [06 §25.2] observed.
@MainActor
public final class AirTrafficControlModel: ObservableObject {
    private let preferences: AppPreferences
    private let workspace: () -> WorkspaceState
    private let makeID: () -> UUID

    @Published public private(set) var routes: [AirTrafficRoute]
    @Published public private(set) var defaultTarget: AirTrafficTarget

    /// - Parameters:
    ///   - workspace: read when the menus are built, for the Space names.
    ///   - makeID: ids of new routes (tests pass a counter).
    public init(preferences: AppPreferences, workspace: @escaping () -> WorkspaceState, makeID: @escaping () -> UUID = UUID.init) {
        self.preferences = preferences
        self.workspace = workspace
        self.makeID = makeID
        routes = preferences.airTrafficRoutes
        defaultTarget = preferences.airTrafficDefaultTarget
    }

    /// "New Route": appends Contains / empty text / Most Recent Space at the end of the list.
    /// [06 §25.2] observed.
    @discardableResult
    public func addRoute() -> UUID {
        let route = AirTrafficRoute(id: makeID())
        routes.append(route)
        save()
        return route.id
    }

    /// ⊖: deletes the route at once, without confirmation. [06 §25.2] observed.
    public func removeRoute(_ id: UUID) {
        routes.removeAll { $0.id == id }
        save()
    }

    public func setMatch(_ match: AirTrafficMatch, for id: UUID) {
        update(id) { $0.match = match }
    }

    public func setPattern(_ pattern: String, for id: UUID) {
        update(id) { $0.pattern = pattern }
    }

    public func setTarget(_ target: AirTrafficTarget, for id: UUID) {
        update(id) { $0.target = target }
    }

    /// The Default row. Also moves the "Open links from other apps in Little Arc" toggle
    /// (see `AppPreferences.airTrafficDefaultTarget`).
    public func setDefaultTarget(_ target: AirTrafficTarget) {
        preferences.airTrafficDefaultTarget = target
        defaultTarget = preferences.airTrafficDefaultTarget
    }

    /// Re-reads the Default row (the Little Arc toggle may have changed elsewhere).
    public func reload() {
        routes = preferences.airTrafficRoutes
        defaultTarget = preferences.airTrafficDefaultTarget
    }

    /// The menu choices, plus `current` when it names a Space that no longer exists (so the menu
    /// still shows the stored choice; [06 §25.4] unknown, our label).
    public func options(including current: AirTrafficTarget? = nil) -> [AirTrafficTargetOption] {
        let ws = workspace()
        let defaultProfile = ws.defaultProfileID
        var options = ws.allLiveSpaces.map { space -> AirTrafficTargetOption in
            var title = space.name
            if space.profileID != defaultProfile, let profile = ws.profiles[space.profileID], !profile.meta.isTombstone {
                title += " (\(profile.name))"
            }
            return AirTrafficTargetOption(target: .space(space.id), title: title)
        }
        if case .space(let id)? = current, !options.contains(where: { $0.target == .space(id) }) {
            options.append(AirTrafficTargetOption(target: .space(id), title: "Deleted Space"))
        }
        options.append(AirTrafficTargetOption(target: .mostRecentSpace, title: "Most Recent Space"))
        options.append(AirTrafficTargetOption(target: .littleArc, title: "Little Arc"))
        return options
    }

    private func update(_ id: UUID, _ change: (inout AirTrafficRoute) -> Void) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        change(&routes[index])
        save()
    }

    private func save() {
        preferences.airTrafficRoutes = routes
    }
}

extension SettingsModel {
    /// A model for the Air Traffic Control sheet, on the app's preferences and workspace.
    public func makeAirTrafficControlModel() -> AirTrafficControlModel {
        let shell = self.shell
        return AirTrafficControlModel(preferences: preferences, workspace: { shell.workspace })
    }

    /// The sheet closed: its Default row may have moved the Little Arc toggle, so the pane redraws.
    public func airTrafficControlDidClose() {
        objectWillChange.send()
    }
}
