import Foundation
import OpenArcEngine
import OpenArcCore

// `BrowserTab.evaluateJavaScript` (plan B71, docs/arc-spec/06-flows.md §29.3) on the bridge's
// `-[OACTab evaluateJavaScript:completionHandler:]` (chromium-bridge/include/OpenArcCore/OACJavaScript.h).
//
// Capability check: framework builds from before B71 have no such method (and no
// OACJavaScript.h), so the wrapper looks the selector up at run time and calls it through its
// implementation pointer. This compiles against both header sets and fails with
// `EngineError.unsupported("evaluateJavaScript")` on an old framework, instead of crashing on an
// unrecognized selector. Once every framework in use has OACJavaScript.h, this can become the
// direct call `tab.evaluateJavaScript(source) { json, error in … }`.

extension ChromiumTabCore {
    /// The bridge selector (OACJavaScript.h).
    static let evaluateJavaScriptSelector = NSSelectorFromString("evaluateJavaScript:completionHandler:")

    /// `OACErrorJavaScriptException` (OACDefines.h, added in B71). A literal so this file also
    /// compiles against headers from before B71.
    nonisolated static let javaScriptExceptionCode = 11

    private typealias EvaluateHandler = @convention(block) (NSString?, NSError?) -> Void
    private typealias EvaluateFunction = @convention(c) (AnyObject, Selector, NSString, EvaluateHandler) -> Void

    func evaluateJavaScript(_ source: String) async throws -> String {
        guard let tab, !tab.isClosed else { throw EngineError.tabClosed(id) }
        let selector = Self.evaluateJavaScriptSelector
        guard tab.responds(to: selector), let implementation = tab.method(for: selector) else {
            throw EngineError.unsupported("evaluateJavaScript")
        }
        let evaluate = unsafeBitCast(implementation, to: EvaluateFunction.self)
        let id = self.id
        return try await withCheckedThrowingContinuation { continuation in
            let handler: EvaluateHandler = { json, error in
                if let error {
                    // `OACErrorJavaScriptException` maps to `.javaScriptException(message)`.
                    continuation.resume(throwing: EngineError(bridge: error, tabID: id))
                } else {
                    continuation.resume(returning: JavaScriptResultText.text(fromJSON: json as String?))
                }
            }
            evaluate(tab, selector, source as NSString, handler)
        }
    }
}
