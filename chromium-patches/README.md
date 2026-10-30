# chromium-patches: Open Arc's changes to Chromium

Open Arc embeds a Chromium fork. The fork is not a long-lived git fork. It is a short, ordered series of patches on top of one upstream release tag, kept in this folder. This is plan task C5. The main session owns this folder (see the ownership table in `CLAUDE.md`).

```
chromium-patches/
├── README.md            this document
├── LICENSE-HEADER.txt   header for every file we add to Chromium's tree
├── apply.sh             applies a series onto a clean tag checkout
├── export.sh            re-exports a series from the local branch
└── 156/                 one directory per Chromium milestone
    ├── BASE             the upstream tag, e.g. 156.0.8078.48
    ├── BRANCH           the local branch the series lives on, e.g. openarc/156
    └── 0001-openarc-*.patch …   `git format-patch` output, applied in order
```

## Model

- **Source of truth while working:** the local branch `openarc/<milestone>` in `~/chromium/src`, one commit per patch, on top of the tag in `BASE`.
- **Source of truth in this repository:** the exported `.patch` files. They are what gets reviewed and what a fresh machine applies.
- Never edit a `.patch` file by hand. Change the commit on the branch (`git commit --amend`, or `git rebase -i` outside this environment), then run `export.sh`.

## Daily use

```sh
# Fresh checkout (gclient sync of the tag, hooks run), then:
chromium-patches/apply.sh                 # ~/chromium/src, newest series
chromium-patches/apply.sh /path/to/src 156

# After changing commits on openarc/156:
chromium-patches/export.sh                # rewrites chromium-patches/156/*.patch
```

`apply.sh` is idempotent. If `openarc/156` already carries exactly the exported patches (compared with `git patch-id`), it does nothing. If the branch exists with different commits, it stops rather than overwrite them. It refuses to run on a tree with uncommitted changes. It applies with `git am --3way`, so small context drift is merged automatically.

`export.sh` writes stable output: no signature, a zero hash in the `From` line, and a fixed abbreviation length. An unchanged commit therefore produces a byte-identical file, and the diff in this repository shows only real changes. It also checks that `//openarc/bridge/public/OpenArcCore` in the branch matches `chromium-bridge/include/OpenArcCore` here, which is the source of truth for the public headers.

Commits on the branch use the author `Open Arc Authors <dev@openarc.invalid>`.

## Building

The `//openarc` targets are not referenced from Chromium's root `BUILD.gn`. Rather than patch that file, the build directory adds them through the existing `root_extra_deps` build argument:

```gn
# out/Release/args.gn (release configuration since C29, decision Q20)
is_debug = false
is_component_build = false
symbol_level = 1
target_cpu = "arm64"
proprietary_codecs = true                          # MP4 / MSE demuxing of H.264, HEVC, AAC
ffmpeg_branding = "Chromium"                       # FFmpeg without H.264 / AAC decoders
media_proprietary_decoders_platform_only = true    # decode only via VideoToolbox / AudioToolbox (patch 0009)
dcheck_always_on = false                           # no DCHECKs in release (B114; not is_official_build: that also turns on LTO/PGO and needs the official toolchain setup)
root_extra_deps = [
  "//openarc:openarc_framework",
  "//openarc:openarc_shell_test",
]
```

Then run `third_party/ninja/ninja -C out/Release openarc_framework openarc_shell_test`, or `chromium-bridge/build-framework.sh`, which also checks the framework and packages it as `app/Vendor/OpenArcCore.xcframework` (plan C8). Use `buildtools/mac/gn` and `third_party/ninja/ninja` directly, because depot_tools' Python wrappers are not initialized here.

## Naming and scope rules

1. **One concern per patch.** A patch does one thing that can be explained in its subject line, for example "let the Mac UI message pump attach to a host-owned run loop". Unrelated changes never share a patch, even if they touch the same file.
2. **File names:** `NNNN-openarc-<area>-<what>.patch`. `NNNN` is the order (0001, 0002, …). `<area>` is the top-level Chromium directory or component (`base`, `content`, `chrome`, `build`, `openarc`). `git format-patch` derives the rest from the subject, so write subjects as `openarc: <area>: <what>`. Example: subject `openarc: base: attach the Mac UI pump to a host run loop` gives `0001-openarc-base-attach-the-Mac-UI-pump-to-a-host-run-lo.patch` (git cuts the name at 64 characters). The `//openarc` patch uses the area `embedder`.
3. **Order:** changes to upstream code come first (lowest numbers), grouped by area in dependency order (`base` before `content` before `chrome`). The patch that adds `//openarc` comes last. It may depend on every earlier patch, and nothing upstream depends on it.
4. **Small upstream diffs.** Prefer an embedder hook such as a virtual method, a `ContentBrowserClient` override or a build argument over editing upstream logic. Mark every upstream edit with an `Open Arc:` comment so a rebase conflict explains itself. Guard platform-specific changes with `BUILDFLAG(IS_MAC)`.
5. **Commit message body:** say why the change is needed, which plan task needs it, and what the upstream behaviour is without it. If an upstream fix would make the patch unnecessary, note it.
6. **No secrets and no Arc internals.** These rules follow from the clean-room rules in `CLAUDE.md`.

## Where `//openarc` lives (decision)

All new code goes in the top-level directory `src/openarc/` of the Chromium tree: the embedder, the Objective-C bridge (`bridge/`), the helper and the test host. **It is kept as patches at the end of the series** (one directory, a few focused commits; they can be squashed), not as a separate repository or a DEPS entry. Reasons:

- It is the simplest workflow that works now. One branch, one export and one apply reproduce the whole tree, with no extra checkout or gclient configuration to keep in sync.
- `//openarc` changes in step with the upstream patches it depends on. Keeping it in the same series keeps them consistent at every point.
- The cost is that `//openarc` history lives as amendments to one commit. If that becomes painful because the directory grows large or has several authors, we will move it to its own git repository mapped into `src/openarc` through a gclient `custom_deps` entry and drop the patch. Nothing else in this workflow would change.

## License header

Every file we add to Chromium's tree, including all of `//openarc`, starts with the text in `LICENSE-HEADER.txt`, commented in the file's syntax:

```
// Copyright 2026 The Open Arc Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
```

The license is BSD-3-Clause, like Chromium's. Its full text is in `src/openarc/LICENSE`, which the header's "the LICENSE file" refers to. Upstream files we modify keep Chromium's header unchanged; our edits there are covered by Chromium's license.

## Rebasing onto a new Chromium tag

Example: moving from 156.0.8078.48 to 157.0.X.Y.

1. **Get the new tag.** Sync the checkout to the new tag (`gclient sync --revision src@refs/tags/157.0.X.Y`, then `gclient runhooks`), or use a separate checkout.
2. **Start a new series.** Create `chromium-patches/157/` with `BASE` (`157.0.X.Y`) and `BRANCH` (`openarc/157`). Keep `156/` until 157 ships.
3. **Rebase the branch.**
   ```sh
   cd ~/chromium/src
   git checkout -b openarc/157 openarc/156
   git rebase --onto refs/tags/157.0.X.Y refs/tags/156.0.8078.48
   ```
   `git rebase` stops at each conflicting commit. Resolve it, keeping the change's intent and its `Open Arc:` comments, then `git add` and `git rebase --continue`. If upstream now does what a patch did, drop the commit (`git rebase --skip`) and note this in the next commit's message. An alternative is `chromium-patches/apply.sh ~/chromium/src 157` after copying the 156 patches into `157/`. `git am --3way` then stops at each conflict, and you resolve it and run `git am --continue`.
4. **Build and run.** Run `gn gen out/Release`, then `ninja -C out/Release openarc_shell_test`, and fix compile errors in `//openarc` from upstream API changes (amend the `//openarc` commit). Run `out/Release/openarc_shell_test https://example.com` and check that the page commits.
5. **Export.** Run `chromium-patches/export.sh ~/chromium/src 157` and review the diff between `156/` and `157/`.
6. **Update references.** Update the plan (`docs/implementation-plan.md`) and the version in `chromium-bridge/README.md` if it is mentioned.

Rebase one milestone at a time. Skipping milestones piles up API changes in `//openarc` at once.

## Current series (156)

| Patch | Concern |
|---|---|
| 0001 | `base`: on Mac, let the UI thread's message pump attach to a run loop that the embedding app already runs (`-[NSApplication run]`), instead of running it. This is the iOS model, extended to `MessagePumpNSApplication`. It adds `CurrentUIThread::Attach()` and `CurrentUIThread::Detach()` on Mac. |
| 0002 | `content`: `ContentMainParams::host_runs_main_loop`, so `RunContentProcess()` returns to the host app instead of shutting content down. The embedder shuts down later. |
| 0003 | `components`: define `ALLOW_RUNTIME_CONFIGURABLE_KEY_STORAGE` on Mac so the embedder can name the keychain item that protects cookies and passwords (`Open Arc Safe Storage`, never Chromium's own). |
| 0004 | `chrome`: `chrome::SetEmbedderOwnsUI()` / `EmbedderOwnsUI()` (`chrome/browser/embedder_owned_ui_mac.h`). In that mode the host's NSApplication is accepted, and Chrome creates no `AppController`, main menu, Services-menu swizzle, initial or last-opened profile, `StartupBrowserCreator` run (first run, profile picker, session restore), quit closure, updater schedule, code-signature clone or `Browser` window; a second launch is dropped and Chrome-initiated exits ask NSApp to terminate. Plan C6b. |
| 0005 | `chrome`: `HistoryTabHelper` records history for tabs of an embedder-owned UI (they are never in a `Browser`). |
| 0006 | `chrome`: `TabHelpers` befriends `openarc::TabHelpersAccess`, so the embedder attaches Chrome's tab helpers to its own WebContents. |
| 0007 | `chrome`: no `StatusTray` (menu bar status items) when an embedding app owns the UI. |
| 0008 | `chrome`: `ExternalProtocolHandler::SetEmbedderDialogRunner()` (Mac): an app that owns the UI draws the "Open <app>?" dialog; Chrome's policy (denied schemes, per-origin memory, flood guard) runs first, and the embedder calls `SetBlockState()` / `LaunchUrlWithoutSecurityCheck()` on acceptance, as Chrome's Views dialog does (plan C12). |
| 0009 | `media`: build argument `media_proprietary_decoders_platform_only` (plan C18, default off): with `proprietary_codecs = true` and `ffmpeg_branding = "Chromium"`, H.264, HEVC and AAC are demuxed by //media and decoded only by VideoToolbox / AudioToolbox. No `FFmpegVideoDecoder`, no OpenH264; `AudioToolboxAudioDecoder` takes every AAC profile and strips ADTS framing; capability answers for H.264 / AAC come from the GPU process. See `chromium-bridge/CODECS.md`. |
| 0010 | `embedder`: the `//openarc` directory, containing the embedder, the bridge, the helper and the test host (plan C6), and the `OpenArcCore.framework` packaging (plan C8). |
| 0011 | `embedder`: the base bundle id (Mach rendezvous, sandbox) comes from the embedding app, so release and development builds do not collide (plan B37). |
| 0012 | `embedder`: keep `//chrome` without its UI (plan C6b, decision Q7): `ChromeMainDelegate` / `ChromeContentBrowserClient` subclasses, profiles through `ProfileManager`, Chrome tab helpers on every tab, favicons from `ContentFaviconDriver`, Chrome's resource packs and crashpad handler in the framework. |
| 0013 | `embedder`: helper apps for the child processes (plan C10): `Open Arc Helper.app`, `… (Renderer)`, `… (GPU)`, `… (Plugin)`, `… (Alerts)` in the framework's `Helpers/`, named in `openarc/app/helpers.gni`, chosen by the browser client from content's and `//chrome`'s child flags; replaces the unbundled `openarc_helper`. |
| 0014 | `embedder`: the keychain item is named after the build, "Open Arc Safe Storage" (release) or "Open Arc Dev Safe Storage" (development build), from the base bundle id (plan C10). |
| 0015 | `embedder`: local crash reports (plan D8, decision Q8): the Crashpad database is `OACApplicationConfiguration.crashDumpDirectory` (the app's "Crash Reports" folder), never Chromium's default; uploads are off at every level (no upload URL, enforced by a `static_assert` against Google Chrome branding; upload consent and the database's upload setting cleared after the handler starts). |
| 0016 | `embedder`: profiles end to end (plan C11): `OACApplication.deleteProfile` removes a profile (Chrome's deletion steps without its Browser-window ones: marked for deletion in Local State, downloads cancelled, data wiped, off-the-record profile destroyed, attributes entry removed) and calls back once `<user data dir>/<UUID>` and its cache directory are gone; `OACProfile.clearBrowsingData` runs Chrome's `BrowsingDataRemover` with `//chrome`'s delegate; the off-the-record profile is destroyed when its last tab closes. |
| 0017 | `embedder`: shell-drawn dialogs and downloads (plan C12): permission prompts (PermissionRequestManager's view, getUserMedia through `MediaCaptureDevicesDispatcher`), HTTP auth (`CreateHttpAuthCoordinator` with a `LoginHandler` / `LoginTabHelper` whose view is the shell's), `<input type=file>` (`RunFileChooser`), external protocol (patch 0008, plus Chrome's `ExternalProtocolObserver` per tab) as `OACDialogDelegate` requests; `OACProfile.downloads` on the profile's `DownloadManager` with //chrome's delegate; SAVE_TO_DISK opens download. |
| 0018 | `embedder`: built-in ad blocking (plan C16): Chromium's subresource filter with the EasyList + EasyPrivacy ruleset from the framework's `Resources/AdBlock` (`chromium-bridge/build-adblock-ruleset.sh`) handed to Chrome's `RulesetService`; forced activation per tab (`DevtoolsInteractionTracker`) from the Local State pref `openarc.ad_blocking.enabled`; per-site allow list in the `ADS` content setting; `OACApplication.adBlockingEnabled`, `OACSiteSettings` (ad blocking and zoom), `OACTab.blockedAdCount`. See `chromium-bridge/README.md` §Ad blocking. |
| 0019 | `chrome`: `ExtensionTabUtil::SetEmbedderTabLookup()`, so `chrome.tabs` resolves the ids of an embedder's own tabs (no `Browser` window). Chrome's PDF viewer needs it to load a document (plan C15). |
| 0020 | `chrome`: `ChromeDevToolsManagerDelegate::SetEmbedderTabPredicate()`, so an embedder's tabs are DevTools "page" and tab targets like `Browser` tabs; without it DevTools shows no Elements, Console or Network (plan C15). |
| 0021 | `embedder`: page tools (plan C15): DevTools in a window of its own per tab (`openarc/browser/openarc_page_tools.mm`), printing through the macOS print panel (`--disable-print-preview`), Save Page As (complete page, HTML only, MHTML; original file for non-HTML), the PDF viewer (lookup of patch 0019), video Picture in Picture through Chrome's PiP window with automatic entry when the user leaves a video tab; `OACTab` API for all of these. |
| 0022 | `embedder`: page top color (plan B45, `06 §17.4`): `openarc/browser/openarc_page_top_color.mm` samples the rendered color at the top-right of the visible page once per finished main-frame load (`CopyFromSurface` of a 3 × 12 DIP area, converted to sRGB and averaged; classic scrollbar detected in an isolated world and reported as such); `OACTabState.pageTopColorKind` / `pageTopColor`, `-[OACTabDelegate tabDidSamplePageTopColor:]`. |
| 0023 | `chrome`: `ManagePasswordsUIController::SetEmbedderBubbleHost()` and `AutofillPopupView::SetEmbedderFactory()` (Mac): an app that owns the UI draws the password save / update bubble and the Autofill dropdown. Chrome's controllers still decide when to prompt, what to suggest, and fill the form; the host builds Chrome's own `SaveUpdateBubbleController` (plan C13). |
| 0024 | `embedder`: the bridge's views for patch 0023 (`openarc/bridge/oac_autofill.mm`, `OACAutofill.h`): `OACPasswordSavePrompt` (username, password length; save / never / decline / dismiss through the bubble controller) and `OACAutofillPopup` (rows, field bounds in view coordinates, highlight; keyboard stays in the page's key press handler; hover and clicks from the shell) as `OACDialogDelegate` requests (plan C13). |
| 0025 | `chrome`: an embedder confirms extension installs and lists its tabs (plan C14): `ExtensionInstallPrompt::SetEmbedderShowDialogCallback()` replaces Chrome's Views install dialog (Web Store "Add to Chrome", `WebstoreInstallWithPrompt`); `ExtensionInstallUIDesktop` shows no "added" bubble under an embedder-owned UI; `ExtensionTabUtil::SetEmbedderTabList()` lets `chrome.tabs.query` list an embedder's tabs (no window id, no index). |
| 0026 | `embedder`: extensions (plan C14, `openarc/bridge/oac_extensions.mm`, `OACExtensions.h`): installed list and per-tab action state (icon PNG, badge, title, popup) for the Site Control Center; `ExtensionActionRunner::RunAction` and popups as `ExtensionViewHost`s whose view the shell hosts (`OACExtensionPopup`, auto-resize 25×25…800×600, close from the page); install confirmations as `OACExtensionInstallRequest`s; Web Store install by id; unpacked loading (turns developer mode on); enable / disable / uninstall; the tab list of patch 0025. |
| 0027 | `chrome`: feature `TFLiteLanguageDetection` (enabled by default) behind `translate::IsTFLiteLanguageDetectionEnabled()`, so an embedder that never downloads the optimization guide's language model can fall back to the CLD3 detector already linked in; without it pages lacking a `lang` attribute are never offered translation (plan B47). |
| 0028 | `embedder`: page translation drawn by the shell (plan B47, `openarc/browser/openarc_translate.cc`, `openarc/bridge/oac_translation.mm`, `OACTranslation.h`): `TranslateBubbleFactory::SetFactory()` routes Chrome's translate steps to a per-tab helper that reports one state (available / translating / translated / failed, source and target language); translate, revert and "never translate this site" run through `TranslateUIDelegate` as Chrome's bubble does; `-[OACProfile resetTranslationSettings]` (`TranslatePrefs::ResetToDefaults`); the API key gate is lifted (the Translate Element library carries its own key); TFLite detection off in every process (patch 0027). |
| 0029 | `embedder`: history and password import from other browsers (plan D3b, `openarc/browser/openarc_importer.mm`, `openarc/bridge/oac_import.mm`, `OACImport.h`): `-[OACProfile importDataOfTypes:fromSource:…]` reads a Chromium-family profile (History; Login Data / Login Data For Account decrypted with the browser's "Safe Storage" keychain key, which macOS asks the user for), Safari's `History.db` (Full Disk Access; reported, never requested) or Safari's export files (ZIP, passwords CSV, history JSON) from temporary copies; history goes through //chrome's `ProfileWriter`, passwords through the password manager's `PasswordImporter` (duplicates skipped, a saved login with another password kept). |
| 0030 | `embedder`: page capture (plan B51, `06 §24`, `openarc/bridge/oac_capture.mm`, `OACCapture.h`): `-[OACTab captureVisibleRect:…]` copies a rectangle of the visible page at the screen's pixel density (`CopyFromSurface` with a source rect); `-[OACTab captureFullPageWithMaximumAspectRatio:…]` renders the whole document through a private DevTools protocol client (`Page.getLayoutMetrics`, then `Page.captureScreenshot` with `captureBeyondViewport` and a content-size clip, optional height limit for portrait mode, scaled down past 16384 px), attached only for the capture. |
| 0031 | `embedder`: link clicks the shell previews (plan B49, Peek, `06 §22`, `openarc/browser/openarc_link_preview.cc`, `openarc/bridge/oac_link_preview.mm`, `OACLinkPreview.h`): `OACTab.linkPreviewTriggers`; a `NavigationThrottle` (added by `OpenArcContentBrowserClient::CreateThrottlesForNavigation`) cancels with `CANCEL_AND_IGNORE` a user link click in the primary main frame to another registrable domain, and `OpenURLFromTab` drops a Shift-click (`NEW_WINDOW`) link open; both report `-tab:didInterceptLinkToURL:trigger:` (`OACLinkPreviewDelegate`) so the shell opens Peek while the tab keeps its page. Tabs without triggers behave as before. |
| 0032 | `embedder`: the Chrome Web Store names Open Arc (plan B61, `06 §18.2`, `§18.3`, `openarc/browser/openarc_web_store_branding.cc`): `WebStoreBranding`, a tab helper, runs a script in Chrome's internal isolated world on every store document (`extension_urls::IsWebstoreDomain`, https, primary main frame, at `PrimaryMainDocumentElementAvailable`) that renames "Add to Chrome" / "Remove from Chrome" to "… Open Arc" (text and aria-labels) and hides the "Switch to Chrome to install extensions and themes" banner and the "Switch to Chrome?" prompt, also in nodes the store adds later (MutationObserver). UA and brands stay Chromium's; installing still goes through `webstorePrivate`. |
| 0037 | `chrome`: an embedder draws the client-certificate picker (plan C25): `SetEmbedderClientCertificateSelector()` (Mac) takes the place of Chrome's tab-modal Views dialog in `ShowSSLClientCertificateSelector()`, after the same checks; Chrome's `AutoSelectCertificateForUrls` policy still runs first. |
| 0038 | `chrome`: an embedder draws the WebAuthn dialog and names its passkey keychain group (plan C21): `AuthenticatorRequestDialogViewController::SetEmbedderFactory()` replaces the Views dialog's controller (the embedder's observes the dialog model and sends its events); `ChromeWebAuthenticationDelegate::SetKeychainAccessGroupOverride()` replaces the compile-time `<team>.<Chrome bundle id>.webauthn` group of profile passkeys. |
| 0039 | `embedder`: client-certificate picker drawn by the shell (plan C25, `openarc/bridge/oac_client_certificate.mm`): `OACClientCertificateRequest` (host:port, matching keychain identities); choose (private key acquired, macOS may ask) or continue without; prompts for one host linked through `SSLClientAuthObserver`; the browser client no longer answers "no certificate" itself. |
| 0040 | `embedder`: passkey and security-key dialog drawn by the shell (plan C21, `openarc/bridge/oac_webauthn.mm`, `OACWebAuthn.h`): `OACWebAuthnDialog` describes the flow's current step (methods, security key, PIN entry / setup / change, touch again, fingerprint enrollment, accounts, passkey creation, errors) and turns the shell's choices into model events; passkeys on this Mac use `<team id>.<bundle id>.webauthn` from the running app's signature (patch 0038). iCloud Keychain passkeys (restricted Apple entitlement), phones (hybrid) and Google Password Manager are not offered. |
| 0041 | `chrome`: `ExtensionUpdater::AllowWebStoreUpdatesWithoutBackgroundNetworking()` (plan C28): with `--disable-background-networking` on, `IsBackgroundUpdateAllowed()` stays true and the updater keeps its normal schedule (soon after start, then every 5 h ± 20 %), but skips installed and pending extensions whose effective update URL is not the Chrome Web Store's (empty means the store). |
| 0042 | `chrome`: `component_updater::DisableComponentUpdaterNetworkForEmbedder()` (plan C27): `ChromeConfigurator` returns no update or ping URL, so components that register on demand despite `--disable-component-update` (the optimization guide's on-device model manifest at every first start; speech, TTS and translate language packs) fail locally instead of reaching `update.googleapis.com` / `dl.google.com`. Extension updates have their own configurator. |
| 0043 | `components`: feature `GaiaCookieListAccountsFetch` (enabled by default) in `GaiaCookieManagerService` (plan C27): disabled, `/ListAccounts` is answered locally with an empty account list, so the sign-in metrics services no longer ask `accounts.google.com` at every profile start. |
| 0044 | `embedder`: no background Google requests from the engine (plan C27, `docs/release.md` §Network use): Local State default `BrowserNetworkTimeQueriesEnabled` false; profile default `alternate_error_pages.enabled` false (no 8.8.8.8 / 8.8.4.4 DNS probes, no captive-portal check); features `TranslateRankerQuery`, `TranslateRankerEnforcement`, `AutofillServerCommunication`, `AimEnabled` (startup `www.google.com/async/folae`) and `GaiaCookieListAccountsFetch` (patch 0043) off; patch 0042 called at startup. |
| 0045 | `embedder`: Web Store extension updates with background networking off (plan C28): calls patch 0041 before any profile loads its extensions. |
| 0046 | `embedder`: back/forward lists that survive a relaunch (plan C20, `openarc/bridge/oac_session_history.mm`, `OACTab.h`): `-[OACTab sessionHistory]` serializes the navigation entries (at most 50 around the current one) as a versioned envelope around `//components/sessions`' `SerializedNavigationEntry` pickles (URL, title, page state with scroll position and form contents); `OACTabConfiguration.sessionHistory` restores them (`NavigationController::Restore` + `LoadIfNecessary`) in place of `initialURL`, which still loads when the data cannot be read. The shell keeps the data per device (`tab-history.plist`), never synced. |
| 0047 | `chrome`/`content`: an embedder handles web notification clicks (plan C24): `NotificationEventDispatcher::GetNonPersistentNotificationDocument()` returns the live document that showed a non-persistent notification; `NonPersistentNotificationHandler::SetEmbedderClickCallback()` (Mac) gets every click after the page's `click` event, with that document's `WebContents` (looked up before the page's handler runs) or null, and replaces Chrome's Browser-tab fallback. |
| 0048 | `embedder`: web notification clicks bring their tab forward (plan C24, `openarc/bridge/oac_notifications.mm`): activates the app and reports `tabDidRequestActivation:` for the tab that showed the notification; when that page is gone, `application:didRequestNewTab:` asks for a foreground tab on the origin in the same profile. Display needed no change: Chrome's Mac notification bridge already delivers banners from the app and `requireInteraction` alerts from the Alerts helper (C10). |
| 0049 | `chrome`: an embedder's tabs get global info bars (plan C23): `GlobalConfirmInfoBar::SetEmbedderTabs()` (Mac) lists the embedder's tabs when a global bar (extension debugger warning, automation, remote debugging) is shown, `EmbedderTabAdded()` reports new tabs; Chrome finds tabs through Browser tab strips otherwise. |
| 0050 | `embedder`: engine info bars drawn by the shell (plan C23, `openarc/bridge/oac_infobars.mm`, `OACInfoBarRequest` in `OACDialogDelegate.h`): every confirm info bar of a tab's `ContentInfoBarManager` becomes a request (message with its template filled in, link, OK / Cancel titles, closeable); accept, decline, close and the link run as in Chrome's views; a bar that stays open is presented again, one that goes away is withdrawn; global bars reach every bridge tab (patch 0049). |
| 0051 | `chrome`: an embedder's keybinding registry names the command's tab (plan C26): `ExtensionKeybindingRegistry::GetActiveWebContentsForCommand()` is virtual (default: the `TabListInterface`'s active tab), so a subclass without a Browser passes the tab that had the keyboard. |
| 0052 | `embedder`: extension keyboard commands and error counts (plan C26, `openarc/bridge/oac_extension_commands.mm`): a per-profile registry subclass keeps the `commands` accelerators (named and `_execute_action`); `PreHandleKeyboardEvent` offers key presses to it before the page; `_execute_action` popups go to `-extensions:didOpenPopup:fromKeyboardOnTab:`; `OACExtensionInfo.errorCount` and `-extensions:didChangeErrorsOfExtension:` from Chromium's error console (developer mode on). |
| 0053 | `chrome`: an embedder draws the address and card save prompts (plan C30, Mac): `ChromeAutofillClient::SetEmbedderAddressSavePrompt()` takes over `ConfirmSaveAddressProfile()` (profile, saved profile it would update, bubble type), `ChromePaymentsAutofillClient::SetEmbedderLocalCardSavePrompt()` takes over `ShowSaveCreditCardLocally()` (card, `SaveCreditCardOptions`); the embedder runs Chrome's decision callback once. Chrome's Views bubbles needed a Browser window (the address one dereferenced a missing one). Saving to the Google account is unchanged. |
| 0054 | `embedder`: address and payment-card save prompts drawn by the shell (plan C30, `openarc/bridge/oac_autofill.mm`, `OACAddressSavePrompt` / `OACCardSavePrompt` in `OACAutofill.h`, `-tab:offerToSaveAddress:` / `-tab:offerToSaveCard:`): envelope-style address, email, phone and the changed values of an update; card network, last four digits, MM/YY, name (the number stays in the engine). Save / No thanks / dropped map to accepted / declined / ignored; account-migration prompts are auto-declined (no Google account); an offer without `show_prompt` ends ignored. |
| 0055 | `chrome`: an embedder opens the tabs and windows extensions ask for (plan C31): `ExtensionTabUtil::SetEmbedderTabOpener()` (foreground / background tab, new window, popup); with it `tabs.create` (current window), `windows.create` (first URL as a new window, others as background tabs; no `tabId`, no incognito) and `runtime.openOptionsPage` / chrome://extensions' options link (`OpenOptionsPageInEmbedder()`: an open options tab comes forward, else a new one) work without Browser windows. |
| 0056 | `embedder`: extension tabs and windows open in the shell (plan C31, `openarc/bridge/oac_extensions.mm`): the opener makes the WebContents (tab helpers, so the extension gets a real tab id) and hands it to `-[OACApplicationDelegate application:didRequestNewTab:]` as a pending-contents request without opener, which the shell adopts like a script-opened window. `OACExtensions.h` header note updated. |
| 0057 | `components`: `component_updater::AllowOnlyComponentsForEmbedder(app_ids)` (plan C33): once called, `CrxUpdateService::RegisterComponent()` refuses every app id not in the list, so such a component is never registered, loaded, checked or downloaded (on-demand requests fail locally with `INVALID_ARGUMENT`); allowed ones update on the normal schedule. |
| 0058 | `embedder`: CRLSet updates, every other component off (plan C33, decision Q21 revised): `PostEarlyInitialization` calls patch 0057 with the CRLSet's app id instead of patch 0042 (no longer called); `PreProfileInit` registers the CRLSet component (`RegisterCRLSetComponent`), which loads `<user data dir>/CertificateRevocation` and checks `update.googleapis.com` 1 min after start, then every 5 h. `--disable-component-update` and `--disable-background-networking` stay. |
| 0065 | `chrome`: an embedder names the window of a WebAuthn request (plan B130, Mac): `ChromeAuthenticatorRequestDelegate::SetEmbedderWindowGetter()`; `ConfigureNSWindow()` asks it when `views::Widget::GetTopLevelWidgetForNativeView()` finds no widget (AppKit windows of an embedder), so `FidoDiscoveryFactory` gets a window and creates the iCloud Keychain discovery. |
| 0066 | `embedder`: iCloud Keychain passkeys in the shell's WebAuthn dialog (plan B130, `openarc/bridge/oac_webauthn.mm`, `OACWebAuthn.h`): the request's window is the tab view's `NSWindow` (patch 0065); mechanism kinds `ICloudKeychain` and `PasskeyInICloudKeychain`. Tests only: `--openarc-fake-icloud-keychain` installs a stand-in for macOS's iCloud Keychain API (`oac_webauthn_test_keychain.mm`, `SetSystemInterfaceForTesting`); nothing in it runs without the switch. |

Patches 0010 to 0018, 0021, 0022, 0024, 0026, 0028 to 0036, 0039, 0040, 0044 to 0046, 0048, 0050, 0052, 0054, 0056 and 0058 are the `//openarc` directory (0033 to 0036 are not listed in the table above yet); they may later be squashed into one. Patches 0019, 0020, 0023, 0025, 0027, 0037, 0038, 0041 to 0043, 0047, 0049, 0051, 0053, 0055 and 0057 change upstream code but come after `//openarc` because they were added while other tasks' commits sat on top of the branch; move them before 0010 at the next rebase (they do not depend on `//openarc`).

Verified on 2026-10-25 (after C18): the series applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produces the same tree hash as `openarc/156`, and `apply.sh` on the existing branch is a no-op.

Verified on 2026-10-26 (after C12, which inserted 0008 and renumbered the later patches; their files are byte-identical apart from the number): the 17 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`507cec150cc5`).

Verified on 2026-10-26 (after C16): the 18 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`72e96496da75`).

Verified on 2026-10-26 (after B45): the 22 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`859442eed292`).

Verified on 2026-10-26 (after C13): the 24 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`0b27e6e48e95`).

Verified on 2026-10-26 (after C14): the 26 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`8fe1512d0051`).
