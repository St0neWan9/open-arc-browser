import Foundation
import OpenArcEngine
import OpenArcImport
import OpenArcPersistence

// Development-build import self test (plan D15). With OPENARC_IMPORT_SELFTEST=<output file> in a
// development build (never the release bundle id), once the first browser window is up the app
// imports from Arc exactly as the sheet's Import button does, with every kind the Arc source
// offers, and writes only counts and statuses to the output file: no names, titles or URLs. Run it
// with OPENARC_DATA_DIR pointing at a throwaway folder. Our own tool; not in the spec.

enum ImportSelfTest {
    static let environmentKey = "OPENARC_IMPORT_SELFTEST"
    /// Wait after the first window registers, so the window is on screen. Own value.
    static let startDelay: Duration = .seconds(1.5)

    /// The output file, or nil (release build, or no variable set).
    static func outputURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String = PersistenceDefaults.bundleIdentifier
    ) -> URL? {
        guard bundleIdentifier != PersistenceDefaults.releaseBundleIdentifier,
              let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Starts the import once per launch.
    @MainActor
    static func startIfRequested(controller: WorkspaceController) {
        guard !didStart, let output = outputURL() else { return }
        didStart = true
        Task { @MainActor [weak controller] in
            try? await Task.sleep(for: startDelay)
            guard let controller else { return }
            let report = await run(controller: controller)
            try? report.write(to: output, atomically: true, encoding: .utf8)
        }
    }

    /// Imports from the Arc source and returns the counts as `key=value` lines. `kinds` limits the
    /// import (nil: every kind the source offers); OPENARC_IMPORT_SELFTEST_KINDS sets it from the
    /// environment as a comma-separated list (`bookmarks,history`), so a run can leave passwords
    /// out (reading another browser's password key may make macOS ask the user).
    @MainActor
    static func run(
        controller: WorkspaceController, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        kinds: Set<ImportDataKind>? = requestedKinds()
    ) async -> String {
        let model = BookmarkImportModel(controller: controller, home: home)
        guard let arc = model.sources.first(where: { $0.id == "arc" }) else { return "error=no Arc source\n" }
        model.selectedSourceID = arc.id
        if let kinds { model.selectedKinds = model.selectedKinds.intersection(kinds) }
        var lines = [
            "offered=" + model.availableKinds(for: arc).map(\.rawValue).joined(separator: ","),
            "selected=" + ImportDataKind.allCases.filter(model.selectedKinds.contains).map(\.rawValue).joined(separator: ","),
        ]
        await model.importSelected()
        if case .failed = model.phase { lines.append("phase=failed") }
        if let s = model.lastSidebarSummary {
            lines += [
                "spaces=\(s.spaces)", "folders=\(s.folders)", "tabs=\(s.tabs)", "todayTabs=\(s.todayTabs)",
                "favorites=\(s.favorites)", "existingFavorites=\(s.existingFavorites)", "splits=\(s.splits)",
                "skipped=\(s.skipped)", "spacesFromOtherProfiles=\(s.spacesFromOtherProfiles)",
            ]
        } else {
            lines.append("sidebar=none")
        }
        if let e = model.lastEngineResult {
            lines += [
                "historyStatus=\(e.historyStatus)", "historyCount=\(e.historyCount)",
                "passwordStatus=\(e.passwordStatus)", "passwordCount=\(e.passwordCount)",
                "passwordConflicts=\(e.passwordConflicts)", "passwordFailures=\(e.passwordFailures)",
            ]
        }
        lines.append("liveSpacesAfter=\(controller.workspace.allLiveSpaces.count)")
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor private static var didStart = false

    static let kindsEnvironmentKey = "OPENARC_IMPORT_SELFTEST_KINDS"

    static func requestedKinds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<ImportDataKind>? {
        guard let raw = environment[kindsEnvironmentKey], !raw.isEmpty else { return nil }
        return Set(raw.split(separator: ",").compactMap { ImportDataKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }
}
