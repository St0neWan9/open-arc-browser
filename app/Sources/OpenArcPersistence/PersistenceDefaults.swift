import Foundation

/// File locations and format constants for local persistence.
public enum PersistenceDefaults {
    /// Placeholder bundle id of the release build (CLAUDE.md). `AppIdentity` in OpenArcShell
    /// builds on these values; they live here because this module must not import the shell.
    public static let releaseBundleIdentifier = "org.openarc.browser"

    /// Bundle id of the development build (`scripts/make-app.sh --dev`, "Open Arc Dev"), so test
    /// instances never share an id with the release app (plan B37).
    public static let developmentBundleIdentifier = "org.openarc.browser.dev"

    /// The running app's bundle id: `Bundle.main`'s when it is one of ours (the release id or
    /// `<release id>.<variant>`), else the release id (a bare `swift run` executable, a test host).
    public static var bundleIdentifier: String {
        bundleIdentifier(mainBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// The bundle id to use when the main bundle's id is `mainBundleIdentifier`: that id when it is
    /// ours, else the release id.
    public static func bundleIdentifier(mainBundleIdentifier: String?) -> String {
        guard let id = mainBundleIdentifier, isOwnBundleIdentifier(id) else { return releaseBundleIdentifier }
        return id
    }

    /// True for the release id and for `<release id>.<variant>`, where the variant is one label of
    /// lowercase letters, digits and hyphens (`dev`).
    public static func isOwnBundleIdentifier(_ id: String) -> Bool {
        if id == releaseBundleIdentifier { return true }
        let prefix = releaseBundleIdentifier + "."
        guard id.hasPrefix(prefix) else { return false }
        let variant = id.dropFirst(prefix.count)
        return !variant.isEmpty && variant.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `~/Library/Application Support/<bundle id>/` for the running app (so the development build
    /// keeps its own data). `OPENARC_DATA_DIR` overrides it (`AppDataLocation` in the shell).
    public static var defaultDirectory: URL {
        defaultDirectory(bundleIdentifier: bundleIdentifier)
    }

    /// `~/Library/Application Support/<bundleIdentifier>/`.
    public static func defaultDirectory(bundleIdentifier: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// The workspace file. Persisted name; never rename.
    public static let workspaceFileName = "workspace.json"
    /// Opaque sync backend state, stored next to the workspace file. Persisted name; never rename.
    public static let syncStateFileName = "sync-state.bin"
    /// Prefix of a corrupt workspace file that was moved aside: `workspace.corrupt-<timestamp>.json`.
    public static let corruptFilePrefix = "workspace.corrupt-"

    /// Coalescing window for autosave: a change is written at most this long after the first
    /// unsaved change. Our own choice (not from the spec).
    public static let autosaveDelay: TimeInterval = 1
}

/// Errors surfaced by `WorkspaceStore`.
public enum PersistenceError: Error, Hashable, Sendable {
    /// The file was written by a newer app version. The store refuses to overwrite it.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The store is read-only because its file could not be loaded safely (see `WorkspaceLoadResult`).
    case readOnly
    /// Encoding the workspace failed; nothing was written.
    case encodingFailed(String)
    /// A file system operation failed.
    case io(String)
}
