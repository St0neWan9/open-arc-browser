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

All new code goes in the top-level directory `src/openarc/` of the Chromium tree: the embedder, the Objective-C bridge (`bridge/`), the helper and the test host. **It is kept as one patch** (the last one in the series), not as a separate repository or a DEPS entry. Reasons:

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
| 0003 | `embedder`: the `//openarc` directory, containing the embedder, the bridge, the helper and the test host (plan C6), and the `OpenArcCore.framework` packaging (plan C8). The embedder is content-level for now; `//chrome` is plan C6b. |
| 0004 | `embedder`: the base bundle id (Mach rendezvous names, the sandbox's `bundle-id`) comes from the app that embeds `OpenArcCore.framework` when it is ours (`org.openarc.browser` or `org.openarc.browser.dev`), else the release id, so the release and development builds never share names (plan B37). |

Verified on 2026-10-25: `apply.sh` onto a clean `156.0.8078.48` worktree produces the same tree hash as `openarc/156`, and a second run is a no-op.
