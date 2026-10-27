import Foundation

// Running JavaScript in a page for the AppleScript `execute` command (plan B71). Spec:
// docs/arc-spec/06-flows.md §29.3 (observed: `execute` takes `javascript` text and returns text;
// unknown: how the value becomes text, inferred "serialized like Chrome, empty when there is no
// value") and §29.4 (the Allow JavaScript from Apple Events gate, which the shell checks before
// calling the engine). Bridge: `-[OACTab evaluateJavaScript:completionHandler:]`
// (chromium-bridge/include/OpenArcCore/OACJavaScript.h).

/// How `BrowserTab.evaluateJavaScript(_:)` turns the page's completion value into text. Engines
/// hand over the value as compact JSON text, or nil when the page produced none (`undefined`):
/// - a JSON string is returned unquoted and unescaped;
/// - `null` and `undefined` give an empty string;
/// - any other JSON value (number, boolean, array, object) is returned as the engine's JSON text.
/// Text that is not JSON is returned unchanged. [06 §29.3] inferred.
public enum JavaScriptResultText {
    public static func text(fromJSON json: String?) -> String {
        guard let json else { return "" }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return json }
        switch value {
        case let string as String: return string
        case is NSNull: return ""
        default: return trimmed
        }
    }
}
