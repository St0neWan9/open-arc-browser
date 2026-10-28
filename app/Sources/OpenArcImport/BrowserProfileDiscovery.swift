import Foundation

/// A Chromium-family browser whose profiles keep a `Bookmarks` JSON file, a `History` database and
/// `Login Data` databases.
public struct ChromiumBrowser: Hashable, Sendable, Identifiable {
    /// Stable id for UI selection.
    public let id: String
    /// Name shown in the import sheet and in the new Space's name.
    public let displayName: String
    /// The browser's user data folder, relative to `~/Library/Application Support`.
    public let relativeDataPath: String
    /// The login keychain item ("<Name> Safe Storage", account "<Name>") that holds the key of the
    /// browser's saved passwords (plan D3b). Reading it makes macOS ask the user.
    public let keychainService: String
    public let keychainAccount: String

    public init(id: String, displayName: String, relativeDataPath: String, keychainName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.relativeDataPath = relativeDataPath
        let name = keychainName ?? displayName
        self.keychainService = "\(name) Safe Storage"
        self.keychainAccount = name
    }

    /// The browsers the import sheet looks for, in the order it lists them. inferred (D3): the
    /// spec names no browsers; these are the common Chromium-family ones on macOS.
    public static let known: [ChromiumBrowser] = [
        ChromiumBrowser(id: "chrome", displayName: "Chrome", relativeDataPath: "Google/Chrome"),
        ChromiumBrowser(id: "brave", displayName: "Brave", relativeDataPath: "BraveSoftware/Brave-Browser"),
        ChromiumBrowser(id: "edge", displayName: "Edge", relativeDataPath: "Microsoft Edge", keychainName: "Microsoft Edge"),
        ChromiumBrowser(id: "chromium", displayName: "Chromium", relativeDataPath: "Chromium"),
        ChromiumBrowser(id: "vivaldi", displayName: "Vivaldi", relativeDataPath: "Vivaldi"),
    ]

    /// Arc's Chromium profiles (history and passwords; plan D15). Not in `known`: the import sheet
    /// lists Arc as one source that also brings its sidebar (`ArcSidebarReader`). Chromium names
    /// the password key's keychain item after the product: service "Arc Safe Storage", account
    /// "Arc". inferred.
    public static let arc = ChromiumBrowser(id: "arc", displayName: "Arc", relativeDataPath: "Arc/User Data")
}

/// One profile of a Chromium-family browser that has bookmarks, history or saved passwords.
public struct BrowserProfile: Hashable, Sendable, Identifiable {
    public let browser: ChromiumBrowser
    /// The profile folder name ("Default", "Profile 1", …).
    public let directoryName: String
    /// The profile's own name from the browser's `Local State`, else the folder name.
    public let profileName: String
    /// `<profile folder>/Bookmarks` (may be missing: see `hasBookmarks`).
    public let bookmarksFile: URL
    /// Which of the profile's data files exist (plan D3b).
    public let hasBookmarks: Bool
    public let hasHistory: Bool
    public let hasPasswords: Bool

    public var id: String { "\(browser.id)/\(directoryName)" }
    /// The profile folder.
    public var directory: URL { bookmarksFile.deletingLastPathComponent() }

    public init(
        browser: ChromiumBrowser, directoryName: String, profileName: String, bookmarksFile: URL,
        hasBookmarks: Bool = true, hasHistory: Bool = false, hasPasswords: Bool = false
    ) {
        self.browser = browser
        self.directoryName = directoryName
        self.profileName = profileName
        self.bookmarksFile = bookmarksFile
        self.hasBookmarks = hasBookmarks
        self.hasHistory = hasHistory
        self.hasPasswords = hasPasswords
    }
}

/// Finds the Chromium-family profiles under a home folder that have a `Bookmarks` file, a `History`
/// database or a `Login Data` database.
///
/// Only the browsers' user data folders are listed and the files' existence checked. The only file
/// read here is each browser's `Local State` (for profile names); the chosen profile's `Bookmarks`
/// is read by the shell and its history and passwords by the engine's importer (plan D3b). Nothing
/// under `~/Library/Safari` is touched here (its contents need Full Disk Access). The home folder is
/// a parameter so tests use a temporary fake one.
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
                    let folder = dataDir.appendingPathComponent(name, isDirectory: true)
                    func isFile(_ file: String) -> Bool {
                        var isDirectory: ObjCBool = false
                        return fileManager.fileExists(atPath: folder.appendingPathComponent(file).path, isDirectory: &isDirectory)
                            && !isDirectory.boolValue
                    }
                    let hasBookmarks = isFile("Bookmarks")
                    let hasHistory = isFile("History")
                    let hasPasswords = isFile("Login Data") || isFile("Login Data For Account")
                    guard hasBookmarks || hasHistory || hasPasswords else { return nil }
                    let profileName = names[name].flatMap { $0.isEmpty ? nil : $0 } ?? name
                    return BrowserProfile(
                        browser: browser, directoryName: name, profileName: profileName,
                        bookmarksFile: folder.appendingPathComponent("Bookmarks"),
                        hasBookmarks: hasBookmarks, hasHistory: hasHistory, hasPasswords: hasPasswords
                    )
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
