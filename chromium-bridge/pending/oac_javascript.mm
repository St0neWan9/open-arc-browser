// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Running a script in a tab's page for the AppleScript `execute` command
// (plan B71, docs/arc-spec/06-flows.md §29.3). See OACJavaScript.h.
//
// STAGED SOURCE (plan B71). This file belongs at
// //openarc/bridge/oac_javascript.mm in the Chromium tree; it is kept here
// until the main session commits it on openarc/156 (see
// chromium-bridge/README.md §B71 for the exact steps). It follows
// oac_capture.mm (patch 0030): one self-owned DevTools protocol client per
// call, attached to the tab's page target and detached when done.
//
// Why the DevTools protocol and not RenderFrameHost::ExecuteJavaScript*:
// - ExecuteJavaScript() runs only in WebUI / chrome: pages (it CHECKs
//   CanExecuteJavaScript()), so it cannot run in a web page;
// - ExecuteJavaScriptInIsolatedWorld() hides the page's own globals and its
//   callback cannot tell an exception from a null result;
// - the *ForTests variants are test-only API.
// Runtime.evaluate runs in the main frame's main world, awaits promises,
// returns the value by value and reports exceptions separately.

#import <OpenArcCore/OACJavaScript.h>

#include <optional>
#include <string>
#include <string_view>

#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/values.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/web_contents.h"

#import "openarc/bridge/oac_application_internal.h"
#import "openarc/bridge/oac_tab_internal.h"

namespace {

using EvaluateHandler = void (^)(NSString*, NSError*);

// A script that runs longer than this fails (own value; the spec records no
// timeout, [06 §29.3] unknown). Runtime.evaluate's own `timeout` stops the
// script; the task timer also covers a renderer that never answers.
constexpr base::TimeDelta kEvaluateTimeout = base::Seconds(30);

NSError* ExceptionError(NSString* message) {
  return OACMakeError(OACErrorJavaScriptException, message);
}

// The exception's text: "ReferenceError: x is not defined" (the first line of
// the exception's description, without the stack), else the details' text.
NSString* ExceptionMessage(const base::DictValue& details) {
  std::string text;
  if (const base::DictValue* exception = details.FindDict("exception")) {
    if (const std::string* description = exception->FindString("description")) {
      text = *description;
    } else if (const base::Value* value = exception->Find("value")) {
      // A thrown primitive (`throw "x"`, `Promise.reject(1)`).
      text = value->is_string() ? value->GetString()
                                : base::WriteJson(*value).value_or("");
    }
  }
  if (text.empty()) {
    if (const std::string* details_text = details.FindString("text")) {
      text = *details_text;
    }
  }
  if (const size_t newline = text.find('\n'); newline != std::string::npos) {
    text.resize(newline);
  }
  return text.empty() ? @"The script threw an exception."
                      : base::SysUTF8ToNSString(text);
}

// One evaluation. Owned by itself until Finish(); the handler runs exactly
// once, on the main thread, from a posted task.
class ScriptEvaluation : public content::DevToolsAgentHostClient {
 public:
  ~ScriptEvaluation() override = default;

  static void Start(content::WebContents* web_contents,
                    const std::string& source,
                    EvaluateHandler handler) {
    auto* evaluation = new ScriptEvaluation(handler);
    evaluation->Attach(web_contents, source);
  }

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost* agent_host,
                               base::span<const uint8_t> message) override {
    std::string_view json(reinterpret_cast<const char*>(message.data()),
                          message.size());
    std::optional<base::DictValue> dict =
        base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
    if (!dict) {
      return;
    }
    std::optional<int> id = dict->FindInt("id");
    if (!id || *id != kEvaluateRequest) {
      return;  // An event; this client enables no domain, so none expected.
    }
    if (const base::DictValue* error = dict->FindDict("error")) {
      // A protocol error (for example the page target went away).
      const std::string* message = error->FindString("message");
      Finish(nil, ExceptionError(message ? base::SysUTF8ToNSString(*message)
                                         : @"The script could not run."));
      return;
    }
    const base::DictValue* result = dict->FindDict("result");
    if (!result) {
      Finish(nil, ExceptionError(@"The script could not run."));
      return;
    }
    DidEvaluate(*result);
  }

  void AgentHostClosed(content::DevToolsAgentHost* agent_host) override {
    host_ = nullptr;
    Finish(nil, OACMakeError(OACErrorTabClosed, @"The tab closed."));
  }

 private:
  static constexpr int kEvaluateRequest = 1;

  explicit ScriptEvaluation(EvaluateHandler handler)
      : handler_([handler copy]) {}

  void Attach(content::WebContents* web_contents, const std::string& source) {
    host_ = content::DevToolsAgentHost::GetOrCreateFor(web_contents);
    if (!host_ || !host_->AttachClient(this)) {
      host_ = nullptr;
      Finish(nil, ExceptionError(@"The page cannot run scripts now."));
      return;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ScriptEvaluation::TimedOut,
                       weak_factory_.GetWeakPtr()),
        kEvaluateTimeout + base::Seconds(1));

    base::DictValue params;
    params.Set("expression", source);
    params.Set("returnByValue", true);
    params.Set("awaitPromise", true);
    params.Set("userGesture", false);
    params.Set("replMode", false);
    params.Set("timeout",
               static_cast<double>(kEvaluateTimeout.InMilliseconds()));
    base::DictValue message;
    message.Set("id", kEvaluateRequest);
    message.Set("method", "Runtime.evaluate");
    message.Set("params", std::move(params));
    std::optional<std::string> json = base::WriteJson(message);
    if (!json) {
      Finish(nil, ExceptionError(@"The script could not be sent."));
      return;
    }
    host_->DispatchProtocolMessage(this, base::as_bytes(base::span(*json)));
  }

  // `result` is Runtime.evaluate's result: {result: RemoteObject,
  // exceptionDetails?}.
  void DidEvaluate(const base::DictValue& result) {
    if (const base::DictValue* details = result.FindDict("exceptionDetails")) {
      Finish(nil, ExceptionError(ExceptionMessage(*details)));
      return;
    }
    const base::DictValue* object = result.FindDict("result");
    const std::string* type = object ? object->FindString("type") : nullptr;
    if (!object || !type || *type == "undefined") {
      Finish(nil, nil);
      return;
    }
    // NaN, Infinity, -Infinity, -0, BigInt literals ("12n").
    if (const std::string* literal = object->FindString("unserializableValue")) {
      Finish(base::SysUTF8ToNSString(*literal), nil);
      return;
    }
    if (const base::Value* value = object->Find("value")) {
      std::optional<std::string> json = base::WriteJson(*value);
      if (json) {
        Finish(base::SysUTF8ToNSString(*json), nil);
        return;
      }
    }
    // No value by value (a symbol, or an object the renderer could not
    // serialize).
    Finish(nil, ExceptionError(@"The script's result cannot be returned as text."));
  }

  void TimedOut() {
    Finish(nil, ExceptionError(@"The script did not finish in time."));
  }

  // Detaches, reports and deletes this object.
  void Finish(NSString* json, NSError* error) {
    if (finished_) {
      return;
    }
    finished_ = true;
    weak_factory_.InvalidateWeakPtrs();
    if (host_) {
      host_->DetachClient(this);
      host_ = nullptr;
    }
    EvaluateHandler handler = handler_;
    OACPostToMainThread(^{
      handler(json, error);
    });
    // DispatchProtocolMessage and AgentHostClosed may still be on the stack:
    // delete from a later task.
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                  this);
  }

  EvaluateHandler handler_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  bool finished_ = false;
  base::WeakPtrFactory<ScriptEvaluation> weak_factory_{this};
};

}  // namespace

@implementation OACTab (OACJavaScript)

- (void)evaluateJavaScript:(NSString*)source
         completionHandler:(void (^)(NSString*, NSError*))completionHandler {
  EvaluateHandler handler = [completionHandler copy];
  content::WebContents* contents = self.isClosed ? nullptr : self.webContents;
  if (!contents) {
    OACPostToMainThread(^{
      handler(nil, OACMakeError(OACErrorTabClosed, @"The tab is closed."));
    });
    return;
  }
  if (contents->IsCrashed()) {
    OACPostToMainThread(^{
      handler(nil, ExceptionError(@"The page has crashed."));
    });
    return;
  }
  ScriptEvaluation::Start(contents, base::SysNSStringToUTF8(source), handler);
}

@end
