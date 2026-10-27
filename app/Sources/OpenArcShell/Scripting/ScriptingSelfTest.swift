import Foundation
import OpenArcPersistence

// Development-build scripting self test (plan B70). Apple events from another process need the
// user's Automation permission (macOS asks once per sending app, so an unattended `osascript`
// smoke test times out on the prompt); events a process sends to itself need none. So a smoke
// test can run inside the app: only in a development build (not the release bundle id) and only
// with OPENARC_SCRIPTING_SELFTEST=<file.applescript>. Once the first browser window is scriptable
// the app compiles and runs the file with `NSAppleScript` on a background thread (its events
// still reach the main thread through the normal Apple event path) and writes the result or the
// error to `<file>.out`. Our own tool; not in the spec.

enum ScriptingSelfTest {
    static let environmentKey = "OPENARC_SCRIPTING_SELFTEST"
    /// Wait after the first window registers, so the window and its tabs are on screen. Own value.
    static let startDelay: TimeInterval = 1.5

    /// The script to run, or nil (release build, or no variable set).
    static func scriptURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String = PersistenceDefaults.bundleIdentifier
    ) -> URL? {
        guard bundleIdentifier != PersistenceDefaults.releaseBundleIdentifier,
              let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Starts the script once per launch.
    @MainActor
    static func startIfRequested() {
        guard !didStart, let script = scriptURL() else { return }
        didStart = true
        let thread = Thread {
            Thread.sleep(forTimeInterval: startDelay)
            let text: String
            if let source = try? String(contentsOf: script, encoding: .utf8), let compiled = NSAppleScript(source: source) {
                var error: NSDictionary?
                let result = compiled.executeAndReturnError(&error)
                text = error.map { "error: \($0)" } ?? (result.stringValue ?? "\(result)")
            } else {
                text = "error: cannot read \(script.path)"
            }
            try? text.write(to: script.appendingPathExtension("out"), atomically: true, encoding: .utf8)
        }
        thread.start()
    }

    @MainActor private static var didStart = false
}
