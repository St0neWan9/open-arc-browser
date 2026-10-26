import Foundation

/// A Chromium-family browser whose profiles keep a `Bookmarks` JSON file.
public struct ChromiumBrowser: Hashable, Sendable, Identifiable {
    /// Stable id for UI selection.
    public let id: String
    /// Name shown in the import sheet and in the new Space's name.
    public let displayName: String
    /// The browser's user data folder, relative to `~/Library/Application Support`.
    public let relativeDataPath: String

    public init(id: String, displayName: String, relativeDataPath: String) {
        self.id = id
        self.displayName = displayName
        self.relativeDataPath = relativeDataPath
    }

    /// The browsers the import sheet looks for, in the order it lists them. inferred (D3): the
    /// spec names no browsers; these are the common Chromium-family ones on macOS.
    public static let known: [ChromiumBrowser] = [
        ChromiumBrowser(id: "chrome", displayName: "Chrome", relativeDataPath: "Google/Chrome"),
        ChromiumBrowser(id: "brave", displayName: "Brave", relativeDataPath: "BraveSoftware/Brave-Browser"),
        ChromiumBrowser(id: "edge", displayName: "Edge", relativeDataPath: "Microsoft Edge"),
        ChromiumBrowser(id: "chromium", displayName: "Chromium", relativeDataPath: "Chromium"),
        ChromiumBrowser(id: "vivaldi", displayName: "Vivaldi", relativeDataPath: "Vivaldi"),
    ]
}

/// One profile of a Chromium-family browser that has a `Bookmarks` file.
public struct BrowserProfile: Hashable, Sendable, Identifiable {
    public let browser: ChromiumBrowser
    /// The profile folder name ("Default", "Profile 1", …).
    public let directoryName: String
    /// The profile's own name from the browser's `Local State`, else the folder name.
    public let profileName: String
    public let bookmarksFile: URL

    public var id: String { "\(browser.id)/\(directoryName)" }

    public init(browser: ChromiumBrowser, directoryName: String, profileName: String, bookmarksFile: URL) {
        self.browser = browser
        self.directoryName = directoryName
        self.profileName = profileName
        self.bookmarksFile = bookmarksFile
    }
}

/// Finds the Chromium-family profiles under a home folder that have a `Bookmarks` file.
///
/// Only the browsers' user data folders are listed. The only files read are each browser's
/// `Local State` (for profile names) and, later, the chosen profile's `Bookmarks`; nothing under
/// `~/Library/Safari` is touched (that needs Full Disk Access; Safari is imported from a file the
/// user picks). The home folder is a parameter so tests use a temporary fake one.
public enum BrowserProfileDiscovery {
    public static func discover(
        home: URL,
        browsers: [ChromiumBrowser] = ChromiumBrowser.known,
        fileManager: FileManager = .default
    ) -> [BrowserProfile] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var result: [BrowserProfile] = []
        for browser in browsers {
            let dataDir = support.appendingPathComponent(browser.relativeDataPath, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dataDir.path) else { continue }
            let names = profileNames(localState: dataDir.appendingPathComponent("Local State"))
            let profiles = entries
                .filter { isProfileFolder($0) }
                .compactMap { name -> BrowserProfile? in
                    let file = dataDir.appendingPathComponent(name, isDirectory: true).appendingPathComponent("Bookmarks")
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
                    let profileName = names[name].flatMap { $0.isEmpty ? nil : $0 } ?? name
                    return BrowserProfile(browser: browser, directoryName: name, profileName: profileName, bookmarksFile: file)
                }
                .sorted { order($0.directoryName) < order($1.directoryName) }
            result.append(contentsOf: profiles)
        }
        return result
    }

    /// "Default" and "Profile N" are user profiles; "System Profile" and "Guest Profile" are not.
    static func isProfileFolder(_ name: String) -> Bool {
        name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst("Profile ".count)) != nil)
    }

    /// Default first, then Profile 1, 2, … numerically.
    private static func order(_ name: String) -> Int {
        name == "Default" ? 0 : (Int(name.dropFirst("Profile ".count)) ?? Int.max - 1) + 1
    }

    /// `profile.info_cache.<folder>.name` from the browser's `Local State` JSON. Empty when the
    /// file is missing or unreadable.
    static func profileNames(localState: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: localState),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = top["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }
        var names: [String: String] = [:]
        for (folder, value) in cache {
            if let info = value as? [String: Any], let name = info["name"] as? String { names[folder] = name }
        }
        return names
    }
}
