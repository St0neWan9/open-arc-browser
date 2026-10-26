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
# out/Release/args.gn
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

Patches 0010 to 0018 are the `//openarc` directory; they stay last and may later be squashed into one.

Verified on 2026-10-25 (after C18): the series applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produces the same tree hash as `openarc/156`, and `apply.sh` on the existing branch is a no-op.

Verified on 2026-10-26 (after C12, which inserted 0008 and renumbered the later patches; their files are byte-identical apart from the number): the 17 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`507cec150cc5`).

Verified on 2026-10-26 (after C16): the 18 patches applied onto a clean `156.0.8078.48` worktree (`git am --3way`) produce the same tree hash as `openarc/156` (`72e96496da75`).
