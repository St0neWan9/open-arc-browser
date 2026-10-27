// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// OACJavaScript: running a script in a tab's page for the AppleScript `execute` command (plan B71,
// docs/arc-spec/06-flows.md §29.3 observed command, §29.4 gate checked by the shell).
//
// Maps to: `BrowserTab.evaluateJavaScript(_:)` (app/Sources/OpenArcEngine/BrowserEngine.swift); the
// Swift side turns the JSON text into the script's result text (`JavaScriptResultText`,
// app/Sources/OpenArcEngine/JavaScriptEvaluation.swift).
//
// The bridge evaluates through the DevTools protocol's `Runtime.evaluate` on the tab's page target
// (its own protocol client, attached for the call and detached afterwards, like the full-page
// capture of OACCapture.h): the main frame's main world, so the page's own globals are visible;
// the page's Content Security Policy does not block it (as in the DevTools console); a returned
// promise is awaited. No user gesture is granted.

#import <OpenArcCore/OACTab.h>

NS_ASSUME_NONNULL_BEGIN

@interface OACTab (OACJavaScript)

/// Runs `source` in the main frame and reports its completion value on the main thread:
/// - `resultJSON`: the value serialized as compact JSON (`"text"` for a string, `2`, `true`,
///   `null`, `[1,2]`, `{"a":1}`); for values JSON cannot hold (`NaN`, `Infinity`, `-0`, a BigInt
///   such as `12n`) the JavaScript literal text instead; nil for `undefined`.
/// - `error`: `OACErrorJavaScriptException` when the script throws, its promise rejects, the value
///   cannot be returned by value (for example a cyclic object), or it does not finish within 30 s;
///   the description is the page's exception text (for example "ReferenceError: x is not defined").
///   `OACErrorTabClosed` after `-close` (or when the tab closes before the script finished).
/// Exactly one of the two is set, except for `undefined` where both are nil.
- (void)evaluateJavaScript:(NSString *)source
         completionHandler:(void (^)(NSString *_Nullable resultJSON, NSError *_Nullable error))completionHandler
    NS_SWIFT_NAME(evaluateJavaScript(_:completionHandler:));

@end

NS_ASSUME_NONNULL_END
