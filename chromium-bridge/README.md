# chromium-bridge: the OpenArcCore bridge

This folder holds the design and the public Objective-C API of `OpenArcCore.framework`, the layer between the Swift shell (`app/`) and our Chromium 156 fork (plan C7), and the script that builds the framework (plan C8). The headers compile against the macOS SDK alone (`check-headers.sh`); the implementation is the `.mm` files inside `//openarc` in the Chromium tree (C6, C8; events C9).

```
chromium-bridge/
├── README.md                      this document
├── SWIFT_PROTOCOL_CHANGES.md      gaps in app/Sources/OpenArcEngine found by this design (for review, not applied)
├── build-framework.sh             ninja build of OpenArcCore.framework -> app/Vendor/OpenArcCore.xcframework (C8)
├── build-adblock-ruleset.sh       EasyList + EasyPrivacy -> the framework's Resources/AdBlock (C16)
├── check-headers.sh               syntax check: Objective-C, Objective-C++ and Swift 6 import
├── check/SwiftImportCheck.swift   type-checked by the script; shows the API as Swift sees it
└── include/OpenArcCore/           public headers of OpenArcCore.framework
    ├── OpenArcCore.h              umbrella
    ├── OACDefines.h               export macros, error domain, OACOrigin, OACColor, OACSecurityLevel
    ├── OACBrowserApplication.h    NSApplication subclass (the app's NSPrincipalClass)
    ├── OACApplication.h           engine start/stop, version, data directory, profile loading
    ├── OACProfile.h               one browsing context per model Profile; off-the-record variant
    ├── OACTab.h                   one web contents: configuration, state, commands, view, snapshot
    ├── OACTabDelegate.h           tab events and new-tab / close requests
    ├── OACDialogDelegate.h        shell-drawn dialogs (C12)
    ├── OACAutofill.h              password save prompt and autofill dropdown (C13)
    ├── OACSiteSettings.h          per-site settings (SiteSettingsProvider)
    ├── OACDownloads.h             a profile's downloads (C12, Library ▸ Downloads)
    ├── OACExtensions.h            a profile's extensions, action popups, install confirmation (C14)
    ├── OACTranslation.h           page translation state and commands, translation settings reset (B47)
    ├── OACCapture.h               visible-rectangle and full-page capture (B51)
    ├── OACJavaScript.h            run a script in the page for AppleScript `execute` (B71)
    └── OACAutocomplete.h          history search and search suggestions for the command bar (B66)
```

The design is our own. It uses only Chromium's public embedder concepts (the content API and the `//chrome` layer's services); it does not follow any other browser's bridge.

## Layers

```
OpenArcShell (SwiftUI)          talks only to the BrowserEngine / BrowserTab / TabSurface protocols
        │
OpenArcChromium (Swift, C8)     implements BrowserEngine on top of OpenArcCore; AsyncStreams, actor hops
        │  import OpenArcCore (Clang module of the framework)
OpenArcCore.framework (ObjC++)  the headers in include/; .mm implementation lives in //openarc
        │  C++
//chrome + //content (Chromium) ProfileManager, Profile, WebContents, tab helpers, services
```

- `OpenArcChromium` is a new Swift target (plan C8). It depends on `OpenArcEngine`, `OpenArcModel` and the `OpenArcCore` binary target (an xcframework). It is the only Swift code that sees an `OAC*` type. It imports no SwiftUI; it needs AppKit only for the `NSView` it passes through as `AnyObject`, and the headers forward-declare `NSView`, so it can even avoid that.
- Nothing above the framework sees a C++ type. The public headers are pure Objective-C (they also compile as Objective-C++, which the `.mm` files need).

## Process model

Chromium is multi-process; our app is its browser process.

| Process | What it is | Where it lives |
|---|---|---|
| Browser | The app itself, `Open Arc.app/Contents/MacOS/OpenArcApp`. Runs the SwiftUI shell and Chromium's browser process (UI thread, IO thread, thread pool) in one address space. | app bundle |
| Renderer | One per site instance group (site isolation on), sandboxed (`renderer` Seatbelt profile). Also JIT-using utility processes. | `Open Arc Helper (Renderer).app` |
| GPU | Compositing, raster, video decode, sandboxed (`gpu` profile). Runs in the plain helper unless SwiftShader may run (content's `CHILD_GPU`), then in the GPU helper. | `Open Arc Helper.app` or `Open Arc Helper (GPU).app` |
| Utility | Network service, storage service, audio, data decoder and others, each sandboxed with its own profile (`network`, `service`, `audio`, …). | `Open Arc Helper.app` |
| Plugin | No PPAPI in 156. Reserved for library CDMs signed by another team (C18); no process type launches it yet. | `Open Arc Helper (Plugin).app` |
| Alerts | Notification service for alert-style web notifications (an app shows either banners or alerts). | `Open Arc Helper (Alerts).app` |

The helpers all run the same tiny executable (`//openarc/app/openarc_helper_main.cc`): it enters the Seatbelt sandbox from the browser's `--seatbelt-client` handshake, `dlopen`s the framework's library four directories up, and calls `OACChildProcessMain` (exported, not in the public headers because only helpers call it). The browser process does not use Chromium's `main()`: the app starts normally (SwiftUI `@main`), and `OACApplication.startWithConfiguration:` runs Chromium's browser startup in place.

### Startup sequence

1. `Info.plist` sets `NSPrincipalClass = OACBrowserApplication`. SwiftUI's `NSApplication.shared` instantiates it, so the shell's scenes and the app delegate adaptor work unchanged.
2. In `applicationWillFinishLaunching` (or the first moment `AppDependencies.live()` runs), `OpenArcChromium` calls `OACApplication.shared.start(configuration:)` with the user data directory `<app data dir>/Chromium` (the app data dir honours `OPENARC_DATA_DIR`, see `app/README.md` §Data directory).
3. Inside, the bridge runs the content main runner with our main delegate, which builds the command line, initializes ICU, feature list, crashpad (local only, decision Q8), field trials off, then the browser main parts: `//chrome`'s browser main parts with our own `ChromeBrowserMainExtraParts`-style hook that skips Chrome's first-run, startup browser creation and session restore. The run loop step is not run by Chromium: AppKit already runs the main run loop, and Chromium's message pump on Mac is a CFRunLoop source, so it drives the UI thread from the existing loop.
4. `start` returns when the UI thread can create profiles and tabs. The shell then restores its own workspace and calls `makeTab` for the tabs it shows; Chromium never restores tabs itself (our sidebar is the source of truth for tabs).

### Shutdown

`applicationShouldTerminate:` returns `.terminateLater`; the termination flush (`LaunchFlow`) first flushes `WorkspaceStore`, then calls `OACApplication.shutdown`, which closes every tab without unload handlers, destroys profiles (flushing cookies, prefs, history), and stops Chromium's threads. Its completion calls `reply(toApplicationShouldTerminate: true)`. Chromium cannot restart in one process, so `OACApplicationStateTerminated` is final.

## Threading

- Chromium's `BrowserThread::UI` is the macOS main thread. Every `OAC*` class that is not an immutable value is `NS_SWIFT_UI_ACTOR` (`@MainActor` in Swift). Immutable snapshots (`OACTabState`, `OACOrigin`, `OACSiteSettingsState`, `OACDownloadItem`, `OACExtensionInfo`, `OACNavigation`) are `NS_SWIFT_SENDABLE`.
- Calling into the bridge off the main thread is a programming error (the implementation `DCHECK`s it in debug builds).
- Callbacks (delegates, observers, completion handlers) always arrive on the main thread, from a posted task: never re-entrantly inside a call the shell made, never while Chromium iterates an observer list. This lets the shell mutate the workspace from a callback, including closing the tab that called it.
- Results that come from other threads in Chromium (snapshot readback, cookie counts, profile loading on the thread pool, the network service) are posted back to the UI thread before the handler runs.

### From callbacks to the Swift protocols

The Swift protocols are `Sendable` and their methods are `async` and nonisolated. `OpenArcChromium` bridges the two worlds like this:

```swift
// Sketch of the C8 wrapper (not part of this task's code).
final class ChromiumTab: BrowserTab, @unchecked Sendable {      // state behind the main actor
    let id: EngineTabID
    private let broadcaster = AsyncBroadcaster<TabEvent>()     // already thread-safe

    func load(_ url: URL) async throws {
        try await MainActor.run { try self.tab.load(url) }      // hop to the UI thread
    }
    func events() -> AsyncStream<TabEvent> {
        // The snapshot must be read on the main actor; see SWIFT_PROTOCOL_CHANGES.md §11.
        broadcaster.subscribe(initial: [.snapshot(lastState)])
    }
}

extension ChromiumTabDelegateAdapter: OACTabDelegate {         // @MainActor via the header
    func tab(_ tab: OACTab, didChangeTitle title: String) {
        lastState.title = title
        broadcaster.yield(.titleChanged(title))                 // delivered to every subscriber
    }
}
```

- Commands hop to the main actor with `MainActor.run` (or the wrapper type is `@MainActor` itself and the nonisolated requirements are satisfied with `nonisolated` + `await`).
- Events are yielded into the existing `AsyncBroadcaster`, which is lock-protected and can be fed from the main thread. The `.snapshot` contract (first element of every stream) is kept by caching the last state in the wrapper and updating it in the same main-thread turn as the yield.
- `WorkspaceController` already consumes events on the main actor, so the hop back is one task enqueue.

## Ownership and lifetimes

| Object | Owner | Lifetime | Swift side |
|---|---|---|---|
| `OACApplication` | singleton, process | `start` → `shutdown` | held by the `ChromiumEngine` |
| `OACProfile` (on disk) | Chromium's `ProfileManager` owns the `Profile`; the `OACProfile` is a weak handle that reports `isValid` | loaded on first use, until shutdown or `deleteProfile` | cached per `Profile.ID` in the engine |
| `OACProfile` (off the record) | the original `Profile` owns its OTR profile | until its last tab closes and nothing references it | the incognito controller's tabs reference it through their configuration |
| `OACTab` | the **`OACTab` object owns its `WebContents`** (a `std::unique_ptr` in the ObjC++ ivar) | creation → `close` (explicit, or releasing the last reference) | the engine holds one strong `OACTab` per live `EngineTabID`; `closeTab` calls `close` and drops it |
| `nativeView` | the `WebContents`' view, retained by the `OACTab` | as long as the tab is open | `SurfaceHost` adds it as a subview; `TabSurface.detach` removes it; never retained beyond the tab |
| Dialog requests | the request object holds the Chromium callback | until answered, cancelled, or released (default answer) | presented by the shell as SwiftUI views (C12) |
| `OACNewTabRequest` with pending contents | holds the engine-created `WebContents` until adopted or declined | short; declined automatically if the opener closes | the shell decides placement via `TreeOps.openTab` |

Rules that follow:

- **Weak handles toward Chromium, strong ownership of tabs.** Chromium owns profiles; we own tabs. That matches the model: profiles are long-lived and shared, tabs are created and closed by the shell.
- Delegates are weak on the bridge side (Cocoa convention). The Swift wrapper keeps its delegate adapter alive as long as it keeps the tab.
- The bridge never retains a tab on its own, so there are no hidden live tabs: the set of live `OACTab`s is exactly what the shell's engine map holds. `FakeEngine.tabIDs` has the same meaning.
- An `OACTab` keeps its profile alive (a keep-alive on the Chromium `Profile`), so an off-the-record profile cannot be destroyed under an open incognito tab.

## Keeping `//chrome` without its UI (decision Q7)

Decision Q7 keeps the `//chrome` layer for extensions, autofill and the password manager. Plan row C6 still says "content embedder, not `//chrome` UI"; both hold: we link `//chrome/browser` and its services, but none of its UI.

What we keep:
- `ChromeContentBrowserClient` (subclassed by ours to redirect UI hooks), `ChromeMainDelegate`-equivalent startup, `ProfileManager` and `Profile` (one per model `Profile`; the user data directory is ours, and `Local State` lists only our profiles).
- Keyed services per profile: history, favicon service, password manager, autofill, extensions system, content settings, permission manager, download core service, zoom, Safe Browsing (off by default; no Google API keys), sync off (our sync is CloudKit for the workspace only).
- Tab helpers: the bridge calls `//chrome`'s tab helper attachment on every `WebContents` it creates, so features keyed on a tab (find, favicon driver, permissions, password manager driver, autofill driver, extensions tab helper, PDF) behave as in Chrome.
- WebUI pages we need: chrome://extensions, chrome://settings subpages that still make sense, chrome://downloads (until Library has its own), DevTools frontend, PDF viewer.

What we replace:
- `Browser`, `BrowserWindow`, `BrowserView`, `TabStripModel`: not created for our tabs. Chrome code that walks `BrowserList` to find "the active tab" gets a small adapter in our patch set (C5) or a feature switch off. Tabs live in the shell's sidebar; Chromium sees a list of `WebContents` owned by `OACTab`s.
- Omnibox views and the location bar: the shell's command bar (⌘L, ⌘T) already does this. Since B66 the bridge hands the command bar raw history matches and search suggestion bodies (`OACAutocomplete.h`); Chrome's `AutocompleteController` and its providers are not used (§Command bar history and suggestions).
- Every dialog, bubble and infobar: routed to `OACDialogDelegate` (JS dialogs, auth, permissions, file chooser, external protocol), `OACDownloads` (download bubble), `OACExtensions` (install dialog, toolbar, popups), and since C13 the password save bubble and the autofill dropdown (`OACAutofill.h`, also delivered through `OACDialogDelegate`).
- `WebContentsDelegate`: implemented by the bridge per tab, never by `Browser`. `AddNewContents` / `OpenURLFromTab` become `OACNewTabRequest`; `CloseContents` becomes `tabDidRequestClose:`; fullscreen, keyboard events, context menus and find replies go to `OACTabDelegate`.

## Plan tasks and bridge surfaces

| Plan | Bridge surface | Swift protocol today | Status of the gap |
|---|---|---|---|
| C6 embedder start | `OACBrowserApplication`, `OACApplication start/shutdown`, `chromiumVersion`, `userAgent` | none (engine lifetime is implicit) | §10 in SWIFT_PROTOCOL_CHANGES.md |
| C8 framework + `OpenArcChromium` | `OACTab +tabWithConfiguration:`, `tabWithIdentifier:`, navigation, `nativeView`, `setVisible:`, `setFocused:`, `snapshot…`, `close` | `BrowserEngine.makeTab / tab(for:) / closeTab`, `BrowserTab` commands, `TabSurface` | covered |
| C9 events | `OACTabDelegate` state callbacks, `tab:didRequestNewTab:`, `tabDidClose:`, `OACApplicationDelegate` new-tab requests | `TabEvent`, `EngineEvent` | covered, plus §1 (adopting script-opened tabs), §2 (close requests), §6 (extra state), §7 (crash reason) |
| C10 helpers, sandbox, universal | helper bundles, `OACChildProcessMain` (C8/C10, not in these headers) | none | packaging only |
| C11 profiles | `OACApplication loadProfile / deleteProfile`, `OACProfile` (`dataDirectory`, `offTheRecordProfile`, `clearBrowsingData…`) | `TabConfiguration.profileID`, `isOffTheRecord` | covered; §10 for explicit profile deletion |
| C12 dialogs + downloads | `OACDialogDelegate` and its request classes; `OACDownloads`; find (`findString…`) | `BrowserTab.dialogRequests()`, `EngineDownloads` | covered (C12); client certificates not |
| C13 passwords, autofill | `OACAutofill.h`: `OACPasswordSavePrompt`, `OACAutofillPopup` / `OACAutofillSuggestion`; `OACDialogDelegate tab:offerToSavePassword:`, `tab:showAutofillPopup:`, `tab:didUpdateAutofillPopup:` | `EngineDialogRequest.passwordSave` / `.autofillPopup` (`AutofillPopupSession`) | done (C13, patches 0023–0024); see §Passwords and autofill |
| C14 extensions | `OACExtensions` (installed list, actions per tab, `runActionOfExtension:onTab:` → `OACExtensionPopup`, Web Store install, unpacked loading, `OACExtensionInstallRequest`) | `EngineExtensions`, `ExtensionPopup`, `EngineDialogRequest.extensionInstall`, `SiteExtensionAction`, `SiteSettingsProvider.runExtensionAction` | done (C14, patches 0025–0026; see below) |
| C15 DevTools, view source, PDF, PiP, print | `showDevToolsWithPanel:` / `closeDevTools` (own window per tab), `viewSource`, `print` (Swift `printPage()`, macOS print panel), `savePageToURL:format:…` (`OACSavePageFormat`), `hasPictureInPictureVideo` / `enterPictureInPictureAutomatically:` / `exitPictureInPicture`; PDF viewer is `//chrome`'s (needs patch 0019); PiP uses Chromium's own PiP window | `BrowserTab.print / savePage(to:format:) / showDevTools / viewSource / enterPictureInPicture(automatically:) / exitPictureInPicture`, `TabEvent.activationRequested` | done (C15, patches 0019–0021) |
| C16 ad blocking | `OACApplication.adBlockingEnabled` / `adBlockingRulesetVersion`, `OACSiteSettings setAdBlockingEnabled:forOrigin:` / `isAdBlockingEnabledForOrigin:`, `OACTab.blockedAdCount` | `BrowserEngine.adBlocking` (`EngineAdBlocking`), `SiteSettingChange.adBlocking`, `isAdBlockingOn` | done (§Ad blocking) |
| C19 filter-list updates | `-[OACApplication loadAdBlockingRulesetFromDirectory:completionHandler:]` (patch 0035, called through a runtime check) | `EngineAdBlocking.rulesetVersionChanges()`, `AdBlockRulesetUpdater` | done (C19, patch 0035, compiled and verified end to end; §Filter-list updates) |
| B45 page top color (toolbar) | `OACTabState.pageTopColorKind` / `pageTopColor`, `tabDidSamplePageTopColor:` (sampled after each load, patch 0022) | `BrowserTabState.pageTopColor` (`PageTopColor`), `TabEvent.pageTopColorChanged` | done (B45) |
| B47 page translation | `OACTranslation.h`: `OACTab.translationState` (`OACTranslationState`), `translateToLanguage:`, `revertTranslation`, `neverTranslateSite`, `tabDidChangeTranslationState:`; `-[OACProfile resetTranslationSettings]`; `OACApplication.translationTargetLanguages` | `BrowserTabState.translation` (`PageTranslation`), `TabEvent.translationChanged`, `BrowserTab.translate(to:) / revertTranslation() / neverTranslateSite()`, `BrowserEngine.translation` (`EngineTranslation`) | done (B47, patches 0027–0028; §Translation) |
| B51 page capture | `OACCapture.h`: `-[OACTab captureVisibleRect:completionHandler:]`, `-[OACTab captureFullPageWithMaximumAspectRatio:completionHandler:]` (PNG at the screen's density) | `BrowserTab.capture(_:)` with `PageCaptureArea` (`EngineSnapshot`) | done (B51, patch 0030) |
| B71 AppleScript `execute` | `OACJavaScript.h`: `-[OACTab evaluateJavaScript:completionHandler:]` (result as JSON text, `OACErrorJavaScriptException`) | `BrowserTab.evaluateJavaScript(_:)`, `JavaScriptResultText`, `EngineError.javaScriptException` | header and Swift done; patch 0033 (§JavaScript evaluation) |
| B66 command bar history + suggestions | `OACAutocomplete.h`: `-[OACProfile queryHistoryMatchingText:maximumCount:completionHandler:]` (`OACHistoryEntry`), `-[OACProfile fetchSearchSuggestionsFromURL:completionHandler:]`, `OACAutocompleteRequest -cancel` | `BrowserEngine.autocomplete` (`EngineAutocomplete`: `historyMatches`, `searchSuggestions`, `capabilities`), `HistoryMatch`, `SearchSuggestionRequest`, `SearchSuggestionParser` | done (B66, patch 0034, compiled; §Command bar history and suggestions) |
| C17 window tint from the page | `OACTabState.themeColor`, `tab:didChangeThemeColor:hasThemeColor:` (theme-color meta only) | `themeColor` | not needed: `06 §17.4` (E18) observed that the window and sidebar never follow the page |
| C18 system codecs | nothing in the API: decoder routing is inside the GPU / media code | none | — |
| Site Control Center (B13) | `OACSiteSettings` | `SiteSettingsProvider` | 1:1, see `OACSiteSettings.h` header comment; §5 for permission kinds |
| D3b history/password import | Chromium's importer through a later `OACImporter` | `ImportDataKind` | not in this header set |
| D8 local crash reports | `OACApplicationConfiguration.crashDumpDirectory` | none | covered |

## Mapping of the Swift protocols to the bridge

| OpenArcEngine | OpenArcCore |
|---|---|
| `BrowserEngine` | `OACApplication` (+ an engine object in `OpenArcChromium` keeping the tab map) |
| `makeTab(_:)` | `OACTab +tabWithConfiguration:error:` (Swift: `OACTab(configuration:)`) after `loadProfile(identifier:)` |
| `tab(for:)` | `OACTab +tabWithIdentifier:` |
| `closeTab(_:)` | `-[OACTab close]` |
| `events()` (engine) | `OACTabDelegate tab:didRequestNewTab:`, `tabDidClose:`, `OACApplicationDelegate application:didRequestNewTab:` |
| `TabConfiguration` | `OACTabConfiguration` (`profile` = `OACProfile` for `profileID`, or its `offTheRecordProfile` when `isOffTheRecord`; `initialURL`; `opener`; `requestedIdentifier`) |
| `BrowserTab.currentState()` | `OACTab.state` (`OACTabState`) |
| `BrowserTab.events()` | `OACTabDelegate` callbacks (table at the top of `OACTabDelegate.h`) |
| `load / goBack / goForward / reload / stopLoading` | `loadURL:error:`, `goBackWithError:`, `goForwardWithError:`, `reloadBypassingCache:error:` (NO), `stopLoadingWithError:` |
| `setMuted(_:)` | `setMuted:` |
| `snapshot(maxPixelSize:)` | `snapshotWithMaxPixelSize:completionHandler:` |
| `TabSurface.attach(to:)` | `host.show(.native(tab.nativeView))` + `setVisible:YES` |
| `TabSurface.detach()` | `host.clear()` (removes the view) + `setVisible:NO` |
| `TabSurface.setFocused(_:)` | `setFocused:` |
| `EngineTabID` | `NSUUID identifier` |
| `BrowserTabState` / `LoadState` / `NavigationState` / `Favicon` / `AudioState` | `OACTabState` fields |
| `NewTabRequest` / `NewTabDisposition` | `OACNewTabRequest` / `OACNewTabDisposition` |
| `EngineSnapshot` | PNG `NSData` + pixel `CGSize` |
| `EngineError` | `OACErrorDomain` codes |
| `SiteSettingsProvider` (Shell) | `OACProfile.siteSettings` (`OACSiteSettings`) |

## Build and packaging (C8, C10)

As built in C8 (differences from the outline below): the framework is `//openarc:openarc_framework`; `Versions/A/` holds the library (`@rpath/OpenArcCore.framework/Versions/A/OpenArcCore`), `Headers/`, `Modules/module.modulemap`, `Resources/` (`Info.plist`, Chrome's `resources.pak`, `chrome_{100,200}_percent.pak` and `<locale>.lproj/locale.pak` since C6b, `icudtl.dat`, `v8_context_snapshot.arm64.bin`, ANGLE's Metal shader cache), `Helpers/openarc_helper` (one unbundled child executable until C10, below), `Helpers/chrome_crashpad_handler` (local crash reports, C6b) and `Libraries/` (SwiftShader). Exports are limited by `//openarc/bridge/OpenArcCore.exports` (29 symbols: the `OAC*` classes, `OACBridgeAPIVersion`, `OACErrorDomain`, `OACChildProcessMain`). `chromium-bridge/build-framework.sh` builds it, checks install name, exports and headers, and writes `app/Vendor/OpenArcCore.xcframework` (arm64). The app's `NSPrincipalClass` stays `NSApplication`: with `OPENARC_ENGINE=chromium` the app instantiates `OACBrowserApplication` itself before SwiftUI starts, so FakeEngine runs never touch Chromium. The base bundle id (Mach rendezvous names, the sandbox's `bundle-id`) must match between the browser process and its helpers whatever the host is; since B37 (patch 0011) every process reads it from the app that embeds the framework (`org.openarc.browser`, or `org.openarc.browser.dev` for the development build) and falls back to `org.openarc.browser` outside our apps (`openarc_shell_test`, xctest). Header change in C8: `OACColorScheme`, `OACTabConfiguration.preferredColorScheme`, `OACTab.preferredColorScheme` (for `BrowserTab.setPreferredColorScheme`).

As built in C10 (patches 0013–0014):

- **Helper apps.** `Versions/A/Helpers/` holds `Open Arc Helper.app`, `Open Arc Helper (Renderer).app`, `Open Arc Helper (GPU).app`, `Open Arc Helper (Plugin).app` and `Open Arc Helper (Alerts).app` (Chromium's Mac helper model with our names; the list is `//openarc/app/helpers.gni`, which generates the `kHelperName` / `kHelperSuffix_*` constants the browser client uses in `GetChildProcessPath()`), plus `chrome_crashpad_handler`. Each helper's `Info.plist` has `LSUIElement` (no Dock icon; also how `//chrome` tells a helper from the browser process) and a bundle id below `org.openarc.browser.helper`: `.helper`, `.helper.renderer`, `.helper.plugin`, `.helper.alerts`; the GPU helper shares `.helper`, as Chrome's does, because a distinct id can break automatic graphics switching. `scripts/make-app.sh` rewrites the `org.openarc.browser` prefix to the embedding app's id, so the development build's helpers are `org.openarc.browser.dev.helper…`, in line with the base bundle id every process reads from the embedding app (patch 0011). A helper started without `--type` (macOS, for a notification click) exits at once.
- **Signing.** `make-app.sh` signs inside out with the hardened runtime: each helper app with its own entitlements (`app/Bundle/Helpers/*.entitlements`), crashpad, the SwiftShader library, the framework, then the app; `codesign --verify --deep --strict` passes for the release and `--dev` bundles. Entitlements (minimum per process type, each commented in its file): renderer and GPU `com.apple.security.cs.allow-jit` (V8, SwiftShader; Chromium's own helper entitlements carry exactly this key, and `allow-unsigned-executable-memory` is not needed); plugin `disable-library-validation` (foreign-team CDMs, kept after D6). Every helper also carries `disable-library-validation` for now, because ad-hoc signatures have no Team ID and library validation refuses to `dlopen` the framework ("different Team IDs", reproduced in C10); D6's Developer ID signing removes it from all but the plugin helper.
- **Sandbox.** Every child process runs under Chromium's Seatbelt sandbox with its type's profile; nothing in the app path passes `--no-sandbox`. Checked in C10 with `sandbox_check(pid, NULL, 0)` on each helper process (see the plan row). The app itself has no App Sandbox, like Chrome.
- **Keychain.** The os_crypt key (cookies, passwords) lives in the login keychain item "Open Arc Safe Storage" (account "Open Arc") for the release app and "Open Arc Dev Safe Storage" ("Open Arc Dev") for the development build, derived from the base bundle id (patch 0014). Chrome's mock keychain is not used in the app (only `--use-mock-keychain` for unattended test hosts). With ad-hoc signing the item's access list trusts one exact signature, so a rebuilt app may make macOS ask once more for keychain access ("Always Allow").
- **Universal (deferred, plan C10b).** `chromium-bridge/build-framework.sh --universal` is written but not yet exercised: it builds `out/Release` (arm64) and `out/Release_x64` (`target_cpu = "x64"`, otherwise the same `args.gn`; that `args.gn` exists, the build output does not), merges the two frameworks with Chromium's `chrome/installer/mac/universalizer.py` (lipo for differing Mach-O files) into `out/Release_universal/OpenArcCore.framework`, and packages that as the xcframework. `make-app.sh --universal` refuses a framework that is not universal. The x86_64 Chromium build itself (hours) is C10b.

As built in C6b (decision Q7, patches 0003–0007 and 0012 in `chromium-patches/156`): `OpenArcMainDelegate` derives from `ChromeMainDelegate`, `OpenArcContentBrowserClient` from `ChromeContentBrowserClient`, and `OpenArcBrowserMainExtraParts` hooks Chrome's main parts. `OACApplication` turns on Chrome's embedder-owned-UI mode (`chrome::SetEmbedderOwnsUI()`, an Open Arc patch): the host's NSApplication, delegate and menu stay; Chrome creates no `AppController`, menu, status item, startup browser, first-run UI, profile picker, session restore or `Browser` window, and quits only through the host. Chrome's user data directory is `OACApplicationConfiguration.userDataDirectory` (`--user-data-dir`): `Local State` and Chrome's global files at its root, one profile per model `Profile` at `<userDataDirectory>/<UUID>` created by `ProfileManager` (an `OACProfile` keeps it loaded), incognito as the profile's primary off-the-record profile. Defaults: `--no-first-run`, `--no-default-browser-check`, `--disable-sync`, `--disable-component-update`, `--disable-background-networking`; Safe Browsing, Chrome sign-in and background mode off; the os_crypt key in the keychain item "Open Arc Safe Storage" (per build since C10; `--use-mock-keychain` for unattended runs). Every `OACTab` gets Chrome's tab helpers (`openarc::TabHelpersAccess`); favicons come from `ContentFaviconDriver` (history-backed), history is recorded, cookies persist. Chrome's own UI stays off: no Chrome context menu, no client-certificate picker (continues without a certificate); since C12 every other prompt is shell-drawn (below).

As built in C12 (patches 0008 and 0017): //chrome's controllers decide when to ask and what to remember; the bridge replaces only their Views UI with `OACDialogDelegate` requests, which `OpenArcChromium` turns into `EngineDialogRequest`s and the shell draws (`DialogCenter`, `TabDialogOverlay`). Permission prompts: `PermissionRequestManager`'s view factory is the bridge's (`openarc::DialogHost`), one request per prompt group, answers mapped to Accept / AcceptThisTime / Deny / Dismiss; getUserMedia goes through `MediaCaptureDevicesDispatcher`. HTTP auth: `CreateHttpAuthCoordinator` override, Chrome's flow (LoginTabHelper for main-frame 401/407) with a `LoginHandler` whose view is the shell's. `<input type=file>`: the tab's `RunFileChooser` (folder uploads enumerated by `FileSelectHelper`; the File System Access pickers keep Chromium's native panel). External protocols: Chrome's policy, then the embedder dialog hook of patch 0008; each tab carries Chrome's `ExternalProtocolObserver` (user gestures permit a launch). Downloads: `OACProfile.downloads` on the profile's `DownloadManager` with //chrome's `ChromeDownloadManagerDelegate`; the Library's Downloads section lists them. Verified in the dev app against a local page: alert / confirm / prompt answers reach the page, location deny and notification allow reach the page, Basic auth signs in, a chosen file reaches the page, `x-apple-reminderkit:` opens Reminders after "Open", a download lands in ~/Downloads and is listed. Camera / microphone prompts are wired the same way but were not seen (the test Mac has no capture devices; Chromium fails with NotFoundError before asking).

As built in C13 (patches 0023–0024; section §Passwords and autofill below).

As built in C14 (patches 0025 and 0026): //chrome's extension system runs as in Chrome on every on-disk profile (`ExtensionService`, content scripts, service workers, declarativeNetRequest, the Web Store's `webstorePrivate` flow); the bridge replaces only Chrome's toolbar and Views dialogs. `OACExtensions` lists the user's extensions and each action's state for a tab (icon as PNG, badge, title, popup); the shell shows them in the Site Control Center's "Extensions" section (`06 §12`; `06 §17.2`: the toolbar has no extension buttons). Running an action goes through `ExtensionActionRunner::RunAction` (activeTab, then `action.onClicked` or the popup); a popup is an `ExtensionViewHost` whose WebContents view the shell puts in a key-taking floating bubble at the site-controls button (placement inferred), sized by the page's auto-resize (25×25…800×600). Install confirmations come from `ExtensionInstallPrompt`'s embedder hook (patch 0025) as `OACExtensionInstallRequest`s and reach the shell as a tab-modal `.extensionInstall` sheet over the store page. `chrome.tabs.query` lists the bridge's tabs (patch 0025; a shown tab counts as active). Unpacked loading turns Chromium's developer mode on. Not covered: `chrome.tabs.create` / `chrome.windows.*` / `openOptionsPage` (need a Chrome window), side panels, the extension context menu, command shortcuts, `action.openPopup()`; Chromium's "Load unpacked" in chrome://extensions works only with the switch off, since its folder picker is Chrome's own (Extensions ▸ Add Extension… opens the Web Store). The Web Store page itself names Open Arc (plan B61, patch 0032): a tab helper's script in an isolated world renames "Add to Chrome" to "Add to Open Arc" and hides the store's "Switch to Chrome" banner and prompt (`06 §18.3`: the store decides those server-side, not from the UA or brands, which stay Chromium's).

### Outline (C7)

- **Where the code lives.** `//openarc` in the Chromium tree (C6): `BUILD.gn`, the content main delegate, browser client subclass, browser main parts hook, and `bridge/` with the `.mm` files implementing these headers. The headers in `chromium-bridge/include` are the source of truth; `//openarc/bridge/BUILD.gn` copies them into the framework's `Headers/`. Our Chromium changes outside `//openarc` live as patches in `chromium-patches/` (C5).
- **Framework target.** A GN `mac_framework_bundle("OpenArcCore")` producing `OpenArcCore.framework` with `Headers/`, `Modules/module.modulemap` (`framework module OpenArcCore { umbrella header "OpenArcCore.h" export * module * { export * } }`), `Resources/` (Chromium's `.pak` files, `icudtl.dat`, `v8_context_snapshot.bin`, locales) and `Helpers/` (the helper apps, Chrome's own layout). Built with `is_component_build=false` (C3), so Chromium links statically into this one dylib. Symbols are hidden except `OAC_EXPORT` / `OAC_EXTERN`.
- **Swift consumption.** `xcodebuild -create-xcframework -framework OpenArcCore.framework` (arm64 first, universal later: two GN out dirs and `lipo` for C10) gives `OpenArcCore.xcframework`, consumed by a `binaryTarget` in `app/Package.swift` and depended on only by `OpenArcChromium`. `FakeEngine` stays the default for tests and for builds without the xcframework (a package trait or a separate product decides which engine `AppDependencies.live()` uses; to be decided in C8).
- **App bundle.** `scripts/make-app.sh` (D1) copies the framework into `Contents/Frameworks/` and signs inside out: helpers (each with its own entitlements: the renderer gets the JIT entitlements Chromium documents for hardened runtime, the GPU helper the library validation exception if needed), then the framework, then the app. `codesign --verify --deep --strict` is C10's acceptance. The app stays unsandboxed (App Sandbox off), like Chrome; the helpers use Chromium's own seatbelt sandbox, which is what "sandbox on" in C10 means.
- **Header check.** `check-headers.sh` must keep passing on every header change; C8 adds the framework-level check (`swiftc` against the built framework's module map).

## Ad blocking (C16)

Built-in ad blocking runs on Chromium's own subresource filter (`//components/subresource_filter`), the engine Chrome uses for Better Ads enforcement, implemented in `//openarc/browser/openarc_ad_blocker.{h,mm}` (patch 0018).

**Why this engine.** The two engines inside Chromium are the subresource filter and the declarativeNetRequest machinery of extensions. declarativeNetRequest needs the extension system (C14) and an extension to own the rules, and its rule format would need its own EasyList converter. The subresource filter needs neither the Chrome Web Store nor Google's ruleset component: we give Chrome's `RulesetService` an unindexed ruleset ourselves, and it indexes the ruleset once into its memory-mapped flatbuffer format, shares it with every renderer, and filters subresources in Blink and subframe navigations in the browser process. Chromium's `ruleset_converter` turns Adblock Plus filter lists into that format. Cost: element-hiding (cosmetic) rules and `$redirect` / `$removeparam` options are dropped: the ruleset carries URL rules only, so the filter only blocks loads (Chromium's style-rule indexer also DCHECKs on EasyList's mix of global and site-specific selectors). Popups are not filtered.

**Pieces.**
- *Ruleset.* `chromium-bridge/build-adblock-ruleset.sh` (run by `build-framework.sh` after every ninja build; `OPENARC_SKIP_ADBLOCK=1` skips it) downloads EasyList and EasyPrivacy at build time into `app/.build/adblock/` (never committed), converts them with `ruleset_converter` (built from `out/Release`), and installs `ruleset.pb`, `ruleset.version` (`<date>-<sha256 prefix>`) and `ATTRIBUTION` into `OpenArcCore.framework/Versions/A/Resources/AdBlock/`. At startup (`OpenArcBrowserMainExtraParts::PostBrowserStart`) the bridge hands it to Chrome's `RulesetService`, which indexes a new version once into `<user data dir>/Subresource Filter/Indexed Rules/` and publishes it. The component updater stays off (`--disable-component-update`), so Google's own list never replaces ours.
- *Activation.* Chrome activates the filter only on sites Safe Browsing lists, and Safe Browsing is off here (no Google API keys). `AdBlockTabHelper` (attached with the other tab helpers) uses the filter's forced-activation switch, the same switch DevTools' `Page.setAdBlockingEnabled` uses (`DevtoolsInteractionTracker`), and sets it from the global switch before every main-frame navigation. The activation level is "enabled": blocked loads fail, and Blink writes a console message for each one.
- *Per-site allow list.* Chrome's `ADS` content setting. `ALLOW` for a site turns the filter off there (`ProfileInteractionManager` honours it). The setting is per profile, and off-the-record profiles inherit it. Bridge: `-[OACSiteSettings setAdBlockingEnabled:forOrigin:]` / `isAdBlockingEnabledForOrigin:`. The Site Control Center's "Ad Blocking" row goes through `EngineSiteSettingsProvider` (Shell).
- *Global on/off.* The Local State pref `openarc.ad_blocking.enabled` (default on, registered by the bridge), so it holds for every profile and survives restarts. Bridge: `OACApplication.adBlockingEnabled`. Settings ▸ Advanced has "Block ads and trackers". The label is inferred: Arc has the switch ([00 §A]), but `03-settings.md` does not record its wording. The row shows only when the framework has a ruleset.
- *Blocked count per tab.* `OACTab.blockedAdCount` counts the console messages that start with Chromium's blocked-resource text, from Blink for subresources and from the child-frame throttle for frames. The filter keeps no other per-page count that the browser can read. A rebase that changes the text gives a zero count, never wrong blocking.
- Changes to either switch apply to each tab's next page load.

### Filter-list updates (C19)

New rulesets reach users between app releases from our static host ([00 §已定的服务策略] observed: the merged filter rules are static content the project hosts; the design below is ours). **Status: done.** The Swift side and the publishing script are in the repository and tested; the Chromium side is patch 0035 (`openarc: embedder: ad-block filter-list updates`), compiled into the framework and verified end to end against the local test host (below). With a framework older than 0035 the updater sees no bridge method at run time and stays off.

**Host layout** (GitHub Pages next to the Sparkle appcast, `docs/release.md` §Choose the static host; placeholder `https://openarc.github.io/adblock/manifest.json` in `AdBlockRulesetUpdateConfiguration`, which keeps updates off while `isHostPlaceholder` is true):

```
adblock/manifest.json                     {"type":"org.openarc.adblock-ruleset","format":1,"serial":…,"version":"<yyyymmdd>-<hex>",
                                           "ruleset":{"path","size","sha256"},"attribution":{"path","size","sha256"}}
adblock/manifest.json.sig                 base64 Ed25519 signature over the exact bytes of manifest.json
adblock/rulesets/<version>/ruleset.pb     unindexed ruleset (build-adblock-ruleset.sh)
adblock/rulesets/<version>/ATTRIBUTION
```

**Client** (`app/Sources/OpenArcEngine/AdBlockRulesetUpdates.swift`, unit-tested in `AdBlockRulesetUpdateTests`): 30 s after start and then daily, `ChromiumAdBlockUpdates` (OpenArcChromium) runs `AdBlockRulesetUpdater`: fetch manifest + signature (64 KB limit) → verify against the built-in public key(s) before reading the JSON → check `type`, `format`, version shape and safe relative paths → skip unless the version may replace the engine's (same build day or later; equal = no change) → reject a `serial` not above the last accepted one (replay) → download both files (64 MB limit), check size and SHA-256 → write `<user data dir>/Open Arc Ad Block/rulesets/<version>/` under a temporary name, rename it into place, swap the `Current` symlink with `rename(2)`, record `state.json` (serial), keep only the new and previous version. Then `-[OACApplication loadAdBlockingRulesetFromDirectory:completionHandler:]` hands it to Chromium's `RulesetService`, which indexes and publishes it to every renderer without a restart; `EngineAdBlocking.rulesetVersionChanges()` delivers the new version and Settings ▸ Advanced shows it at once. The bridge method is called through a runtime check (`responds(to:)`), so the Swift code runs with frameworks built before the patch. At the next start the engine itself loads `Current` unless the bundled ruleset was built on a later day (an app update with newer lists). A bad signature, hash or size changes nothing on disk.

**Signing key.** Ed25519, generated 2026-10-27. Private key: `~/projects/open-arc-browser-signing/adblock-ruleset-ed25519.pem` (outside the repository; README there). Public key built in: `AdBlockRulesetTrust.openArcPublicKeys`. Rotation: add the new public key, release, sign with the new key, drop the old key later.

**Publishing.** `scripts/publish-adblock-ruleset.sh [--out build/adblock-site]` builds the ruleset (`build-adblock-ruleset.sh <src> <out> -`, stage only), copies it to `<out>/adblock/rulesets/<version>/`, writes and signs the manifest (Homebrew OpenSSL 3; LibreSSL lacks Ed25519), re-verifies it, and refuses a key the app does not trust (`--allow-unknown-key` only for the rejection test). `--from <dir>` publishes an existing ruleset directory. Upload `rulesets/` first, then `manifest.json.sig` and `manifest.json`.

**Applied** (main session, 2026-10-27): the draft went onto `openarc/156` as its own commit after 0034 (it only touches `//openarc`); the only change while compiling was the include order in `openarc_ad_blocker.h`. The public header change is in `chromium-bridge/include/OpenArcCore/OACApplication.h`; `check-headers.sh` and `build-framework.sh` pass, and the exported framework has 71 symbols, all public API. In `ChromiumAdBlocking.swift` the dynamic call may become `app.loadAdBlockingRuleset(from:completionHandler:)` once no older framework is in use.

**Local test host** (acceptance check of C19):

```sh
# 1. a "newer" ruleset: copy the built one and give it a later version
mkdir -p /tmp/oa-next && cp app/.build/adblock/ruleset/{ruleset.pb,ATTRIBUTION} /tmp/oa-next/
echo "$(date -u -v+1d +%Y%m%d)-$(shasum -a 256 /tmp/oa-next/ruleset.pb | cut -c1-12)" > /tmp/oa-next/ruleset.version
scripts/publish-adblock-ruleset.sh --from /tmp/oa-next --out /tmp/oa-site
# 2. serve it (loopback http is allowed by App Transport Security)
python3 -I -m http.server 8765 --bind 127.0.0.1 --directory /tmp/oa-site
# 3. run the dev app against it; the first check runs 30 s after start
OPENARC_ADBLOCK_MANIFEST_URL=http://127.0.0.1:8765/adblock/manifest.json \
    "build/Open Arc Dev.app/Contents/MacOS/OpenArcApp"
log stream --predicate 'category == "adblock-updates"'      # "… loaded"
# Settings ▸ Advanced: the footer shows the new version without a restart.
# 4. bad signature: republish with another key; the log says "rejected: badSignature" and nothing changes
openssl genpkey -algorithm ed25519 -out /tmp/rogue.pem
scripts/publish-adblock-ruleset.sh --from /tmp/oa-next --out /tmp/oa-site --key /tmp/rogue.pem --allow-unknown-key --serial 99999999999999
```

Verified with patch 0035 (2026-10-27, dev app built from a clean worktree, own `OPENARC_DATA_DIR`): with Settings ▸ Advanced already open showing the bundled `20261027-…`, the first check 30 s after start downloaded `20261028-…`, logged "… loaded", Chromium indexed it (`Subresource Filter/Indexed Rules/38/20261028-…`) and the footer switched to `20261028-…` without a restart. After a restart the engine loaded `Current` (the downloaded one), and the check reported "up to date". A manifest signed with another key (higher serial, later version) was logged as "rejected: badSignature" and left the store and `state.json` unchanged.

**Attribution.** EasyList and EasyPrivacy are © The EasyList authors (https://easylist.to/), dual-licensed under Creative Commons Attribution-ShareAlike 3.0 Unported or GNU GPL v3 or later. Open Arc uses them under CC BY-SA 3.0, and the converted ruleset is distributed under the same license. The `ATTRIBUTION` file (list versions, URLs, license) ships next to the ruleset in the framework, and `scripts/make-app.sh` copies it to `Open Arc.app/Contents/Resources/ATTRIBUTION-AdBlock.txt`.

## Passwords and autofill (C13)

Chrome's password manager and Autofill run unchanged on our `//chrome` profiles (C6b, C11): `TabHelpers` attaches `ChromePasswordManagerClient`, `ChromeAutofillClient` and `ManagePasswordsUIController` to every tab. Passwords are stored in the profile's `Login Data` and encrypted by os_crypt with the build's keychain item (patch 0014; the development build passes `--use-mock-keychain`). What Chrome draws with Views is replaced through two Open Arc hooks (patch 0023) by the bridge's views (patch 0024, `openarc/bridge/oac_autofill.mm`):

- **Save prompt.** Where Chrome would pop up its save / update bubble (after a login form submission that navigated on), `ManagePasswordsUIController` asks the bridge's `EmbedderBubbleHost`, which builds Chrome's `SaveUpdateBubbleController` and hands the shell an `OACPasswordSavePrompt` (username, password length; the password never leaves the engine). Save (optionally with an edited username), Never for this site, Not now / No thanks and dismissals go to the bubble controller as from Chrome's Views bubble, so the blocklist and the dismissal counts behave as in Chrome. Only the pending save / update states are shown; the saved confirmation, the manage bubble, leak warnings and passkey bubbles are not (follow-up).
- **Autofill dropdown.** `AutofillPopupView::Create()` returns the bridge's view: one `OACAutofillPopup` per shown popup, with the rows of the controller (saved credentials, addresses, cards, earlier entries, datalist options, "Manage Passwords…"), the field's bounds in the tab view's coordinates, and the highlighted row. Keyboard focus stays in the page; ↑ / ↓ / Return / Tab / Escape / Shift+Delete reach the view through Chrome's key press handler, exactly as for the Views popup, and changes go to the shell with `-tab:didUpdateAutofillPopup:`. The shell forwards hover (`-selectSuggestionAtIndex:`, which previews the row in the form) and clicks (`-acceptSuggestionAtIndex:`; Chrome ignores clicks in the first 500 ms). `containsPointer` keeps the popup open while a click on the shell's dropdown takes focus from the page. Sub-popups (manual fallback lists, field-by-field address filling) are not drawn (follow-up).
- **Swift.** `EngineDialogRequest.passwordSave(PasswordSavePrompt)` (single-shot reply) and `.autofillPopup(AutofillPopup)`, whose `AutofillPopupSession` carries the live rows (`updates()`) and the shell's commands (`.select`, `.accept`, `.pointerInside`). `DialogCenter` queues save prompts like other prompts (a bubble under the URL box, as a permission prompt) and keeps one non-modal dropdown per tab (`autofillPopups`), drawn under the field by `AutofillDropdownView`. Arc's look of both is not recorded (`00 §A`: "style not captured"): unknown.
- **Verified** in the development app against a local login page (made-up credentials): the save prompt appeared after submitting, Save stored the login (encrypted, in the profile's `Login Data`), the revisit filled the form on load, and the dropdown appeared under the cleared username field; a click on its row and ↓ + Return both filled username and password.
- **Not done (follow-ups):** address and credit card save prompts (Chrome's `AutofillBubbleHandler` bubbles; without them nothing saves new addresses or cards, so address and card rows in the dropdown were not exercised), password generation popup, the account chooser / auto sign-in of the Credential Management API, the "Manage Passwords…" row (Chrome opens its password manager page in a `Browser`; with none it does nothing), and a Settings ▸ Profiles ▸ Passwords view (`03 §Profiles` lists Passwords, Credit Cards and Autofill rows; they stay pending).

## Translation (B47)

Chrome's translate component runs unchanged on every tab (`TabHelpers` attaches `ChromeTranslateClient`): the renderer's `TranslateAgent` detects the page language, `TranslateManager` decides whether to offer translation (the page language is not one the user reads; no never-translate list holds the site or language) and translates by injecting Google's Translate Element library into an isolated world. Only the Views bubble is replaced (patch 0028, `openarc/browser/openarc_translate.cc`): Chrome hands every translate step to `TranslateBubbleFactory` when no `Browser` holds the tab, and the embedder's factory forwards it to a per-tab `TranslateTabHelper`, which folds the steps and `LanguageState` into one `OACTranslationState`. The shell draws Arc's surfaces (`06 §19`, E19): a second URL box line "Translation Available" / "Translated" (a toolbar button with the toolbar on), an offer bubble, a native Options menu, no progress UI, and the "Translated back to …! Use ⌘Z to undo." notice; nothing in the Site Control Center.

- **Keys.** `TranslateManager` offers nothing without Google API keys (`HasAPIKeyConfigured`). The translation itself does not need ours: the script Chrome fetches (`translate.googleapis.com/translate_a/element.js`, "library" mode) loads the Translate Element library, which calls `translate-pa.googleapis.com/v1/translateHtml` with the key it carries; the `translateApiKey` Chrome injects (`dummytoken` here) is not used on that path. The bridge lifts the gate (`TranslateManager::SetIgnoreMissingKeyForTesting(true)`, the only switch Chrome has). Verified 2026-10-26 in the development app against a local German page: offer, translate (title and text in English), Use Original, ⌘Z, never translate this site, Settings reset. The language list fetch (`translate-pa…/supportedLanguages`) does need a key (403), so the target languages are Chromium's built-in default list. Risk: this relies on Google's public website-translation endpoint and its terms; if Google drops the library's own key, translations fail with `OACTranslationErrorInitialization` / `Network` and the shell shows its failure note. An own Cloud Translation key (`GOOGLE_API_KEY` at build or run time) would also enable the language list.
- **Language detection.** The TFLite model comes from the optimization guide's downloads, which this build never gets. Patch 0027 puts it behind a feature that the main delegate disables in every process, so the renderer uses CLD3 (pages without a `lang` attribute are detected too).
- **Reset.** Settings ▸ Advanced "Reset Translated-site Prompts" (`03 §Advanced`) calls `-[OACProfile resetTranslationSettings]` for every profile: `TranslatePrefs::ResetToDefaults` (never-translate sites and languages back to the defaults, always-translate pairs, accept / decline counts).
- **Not done.** Partial (selection) translation, PDF translation (Chrome's needs its Read Anything side panel), auto-translate toasts, "Always translate <language>" (Arc's menu has none, `06 §19.3`), off-the-record tabs (Chrome does not offer translation there: `ChromeTranslateClient` skips detection for off-the-record profiles).

## JavaScript evaluation (B71)

The AppleScript `execute` command (`06 §29.3`, gated by View ▸ Developer ▸ Allow JavaScript from Apple Events, `06 §29.4`) runs a script in the tab's page and returns its value as text. The header (`OACJavaScript.h`), the error code `OACErrorJavaScriptException = 11` (`OACDefines.h`) and the Swift side (`app/Sources/OpenArcChromium/ChromiumJavaScript.swift`) are in place. The implementation is `pending/oac_javascript.mm`: like the full-page capture (patch 0030) it attaches its own DevTools protocol client to the tab's page target and sends one `Runtime.evaluate` (`returnByValue`, `awaitPromise`, 30 s timeout, no user gesture), then detaches. That runs in the main world of the main frame (page globals visible, CSP does not block it), awaits promises, and keeps exceptions apart from values. `RenderFrameHost::ExecuteJavaScript` is not usable here (WebUI pages only), and the isolated-world variant hides the page's globals and cannot report exceptions.

Until a framework with the method is built, the Swift wrapper finds no `evaluateJavaScript:completionHandler:` selector on `OACTab` and throws `EngineError.unsupported("evaluateJavaScript")`; the shell reports "This version of Open Arc cannot run JavaScript in a page." to the script.

**Main-session steps (not done by the B71 task):**
1. In `~/chromium/src` on `openarc/156`: copy `chromium-bridge/pending/oac_javascript.mm` to `openarc/bridge/oac_javascript.mm` and `chromium-bridge/include/OpenArcCore/{OACJavaScript.h,OACDefines.h,OpenArcCore.h}` to `openarc/bridge/public/OpenArcCore/`.
2. `openarc/BUILD.gn`: add `"bridge/public/OpenArcCore/OACJavaScript.h"` to `openarc_public_headers` and `"bridge/oac_javascript.mm"` to the `bridge` source set (next to `oac_capture.mm`; the deps `//content/public/browser` and `//base` are already there).
3. Commit as a new patch, subject `openarc: embedder: run a script in the page for AppleScript execute`, then `chromium-patches/export.sh` (writes `0033-…patch`) and delete `chromium-bridge/pending/`.
4. `chromium-bridge/build-framework.sh` (ninja `openarc_framework`, header sync check, xcframework into `app/Vendor/`).
5. Check: `OPENARC_ENGINE_TESTS=1 swift test --filter ChromiumEngineConformanceTests` (its B71 block then exercises strings, numbers, objects, promises, undefined/null and a thrown ReferenceError instead of accepting `.unsupported`), and the B70 `osascript` / self-test `execute` with the gate on. Optionally replace the run-time selector lookup in `ChromiumJavaScript.swift` by the direct call once every framework in use has the header.

## Command bar history and suggestions (B66)

The command bar (`05 §command bar`, `04 §command bar`) lists browsing history pages and the search engine's suggestions (`06 §16.2`, `§19.1`, `§23` observed: a typed word with no matching command lists search suggestions; `03 §Profiles` observed: "Search engine" and "Include search engine suggestions" per profile; `06 §20.1` observed: the incognito bar has no history). The header (`OACAutocomplete.h`) and the Swift side (`app/Sources/OpenArcChromium/ChromiumAutocomplete.swift`) are in place; the implementation is `//openarc/bridge/oac_autocomplete.mm`, patch 0034, compiled into the framework.

- **History**: `HistoryServiceFactory::GetForProfile(profile, EXPLICIT_ACCESS)->QueryHistory(text, options, …)` with `REMOVE_ALL_DUPLICATES`, `kExclude404s` and `max_count` 1…100; each `URLResult` becomes an `OACHistoryEntry` (URL, title, last visit, visit and typed counts; http/https only). Off-the-record profiles answer an empty list (they record no history), and the shell does not ask from an incognito window.
- **Suggestions**: the shell builds the URL from its own `SearchEngine.suggestURLTemplate` (Chromium's TemplateURLService is not consulted, so the profile setting in our model stays the single source of truth); the bridge GETs it with `SimpleURLLoader` on the profile's default storage partition (`credentials_mode = kOmit`, `LOAD_DO_NOT_SAVE_COOKIES | LOAD_DISABLE_CACHE`, 1.5 s timeout, 64 KiB limit, traffic annotation `openarc_search_suggestions`) and returns the body; `SearchSuggestionParser` (OpenArcEngine) reads the OpenSearch JSON. An incognito window sends through its off-the-record profile when that exists (before its first tab it uses the on-disk partition, which keeps nothing of the request).
- **Cancellation**: each call returns an `OACAutocompleteRequest`; `-cancel` drops the history task tracker / URL loader and runs the handler once with an empty result. The Swift wrapper calls it from the calling task's cancellation handler, so each keystroke cancels the previous query.
- **Request lifetime**: a running history query or load keeps its `OACAutocompleteRequest` alive until it finishes, so the handler runs exactly once even if the caller drops the request object.
- **Capability check**: with a framework older than patch 0034, `ChromiumAutocomplete.capabilities` is empty (selectors looked up at run time, `OACHistoryEntry` read by key) and the command bar shows no history and no suggestions; everything else works.

**Main-session steps (steps 1–5 done: patch 0034; step 6's in-app check is still open):**
1. In `~/chromium/src` on `openarc/156`: copy `chromium-bridge/pending/oac_autocomplete.mm` to `openarc/bridge/oac_autocomplete.mm` and `chromium-bridge/include/OpenArcCore/{OACAutocomplete.h,OpenArcCore.h}` to `openarc/bridge/public/OpenArcCore/`.
2. `openarc/BUILD.gn`: add `"bridge/public/OpenArcCore/OACAutocomplete.h"` to `openarc_public_headers` and `"bridge/oac_autocomplete.mm"` to the `bridge` source set; add deps `//chrome/browser/history`, `//components/history/core/browser`, `//components/keyed_service/core`, `//net`, `//services/network/public/cpp` (most are already pulled in by `:importer` / `:embedder`; `gn check` will name any missing one). The exports list already matches `_OBJC_CLASS_$_OAC*`.
3. Build (`autoninja -C out/Release openarc_framework`) and fix what the compiler finds (the file was written against 156 headers but never compiled). If `GURL` from `NSURL` needs it, `net/base/apple/url_conversions.h` is the include.
4. Commit as a new patch, subject `openarc: embedder: history search and search suggestions for the command bar`, then `chromium-patches/export.sh` (writes the next `00NN-…patch`) and delete `chromium-bridge/pending/`.
5. `chromium-bridge/build-framework.sh` (ninja `openarc_framework`, header sync check, xcframework into `app/Vendor/`).
6. Check: `OPENARC_ENGINE_TESTS=1 swift test --filter ChromiumEngineConformanceTests` (its B66 block), then in the app: visit a page, close it (not archive), next day / after relaunch type its title in ⌘T → a clock row; type "swift" → the engine's suggestions after the local rows; Settings ▸ Profiles ▸ "Include search engine suggestions" off → none; an incognito window → suggestions, no history. Optionally replace the run-time selector lookups in `ChromiumAutocomplete.swift` by direct calls once every framework in use has the header.

## Open points for review

1. Whether `OpenArcChromium` should be `@MainActor` throughout and satisfy the nonisolated `BrowserEngine` requirements by hopping, or whether `BrowserEngine` itself becomes `@MainActor` (SWIFT_PROTOCOL_CHANGES.md §11). The bridge works either way.
2. Script-opened tabs (`window.open`) need adoption of an engine-made tab; `NewTabRequest` cannot express it today (§1). Without the change, `window.opener` and `postMessage` to popups (OAuth sign-in flows) break.
3. DevTools docking: the header opens DevTools in its own window; docking it into the web panel needs a second surface per tab, decided in C15.
4. Command bar autocomplete: decided in B66 (raw history + suggestion bodies, shell ranks; §Command bar history and suggestions). Most-visited sites and Chrome's history quick provider (in-memory URL index, prefix matching on typing) are not exposed; revisit if `QueryHistory` latency shows while typing.
