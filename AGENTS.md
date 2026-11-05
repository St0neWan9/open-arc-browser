# Open Arc: guidelines for contributors and coding agents

Open Arc is an independent, open-source macOS browser whose interaction and look follow Arc; icons and animations may differ. The shell is Swift and SwiftUI in `app/`. The web engine is a Chromium fork reached through an Objective-C bridge (`chromium-bridge/`, `chromium-patches/`). Sync uses CloudKit only (CKSyncEngine, private database). AI features are out of scope for v1. The bundle id is `org.openarc.browser`, and the minimum OS is macOS 14.

## Originality
- Open Arc is written from scratch. Never commit anything copied from Arc or The Browser Company: no code, assets, icons, sounds, strings, class names, accessibility identifiers or other internal names. Use our own names.
- Never modify Arc.app or its data. Importing reads the user's own Arc sidebar file, read-only.

## Evidence levels
Values and behaviors that follow Arc carry one of these labels in comments:
- **observed**: measured or seen.
- **inferred**: estimated or derived.
- **unknown**: a placeholder.

Comments cite the design-spec section with the label, for example `[04 §sidebar] observed`. Keep existing citations when you change the code; a new value without a source is `inferred` or `unknown`.

## Module boundaries (`app/`)
- Dependency direction: `OpenArcModel ← OpenArcEngine / OpenArcSyncAPI / OpenArcDesign ← OpenArcShell ← OpenArcApp`. `app/README.md` has the full graph.
- Model imports Foundation only. Engine, SyncAPI, Design, Persistence and Import import no UI framework.
- Only Shell and App may import SwiftUI or AppKit.
- Only `OpenArcSyncCloudKit` imports CloudKit. Only `OpenArcChromium` sees the bridge's `OAC*` types; it implements `BrowserEngine`.
- Every target builds in Swift 6 language mode (`swiftLanguageModes: [.v6]`). Fix concurrency errors with real isolation (`@MainActor`, `Sendable`, `sending`). Each `@unchecked Sendable` or `nonisolated(unsafe)` needs a one-line comment saying why it is safe. Use `@preconcurrency import` only for Apple frameworks.
- Model and tree changes go through the pure functions in `TreeOps`. They take `now` and new ids as parameters, never call `Date()` or `UUID()`, stamp only the field groups they change, and delete by tombstoning.
- Conflict policy: field-group last-writer-wins, delete wins, ties go to the server (`OpenArcSyncAPI/ConflictPolicy.swift`). Any new synced field must join a field group.

## Naming
- Do not give types names that clash with SwiftUI. Use `TabNode`, not `Tab`, and `RGBAColor`, not `Color`. Also avoid `Layout`, `Group`, `Image`, `Window` and `Section`.
- Record type names (`recordTypeName`) and `SyncRecordID.recordName` are persisted. Never rename them.
- Modules are named `OpenArc<Name>`; test targets are `<Module>Tests`.

## Tests
- Every module has a test target.
- New behavior needs a test. Tree operations and the conflict policy must stay covered.
- Tests that read an `AsyncStream` must be bounded: take N elements, or use a stream that finishes.
- Before handing off, run `cd app && swift build && swift test`. Both must pass with no warnings.
- Parallel builds must not share `app/.build`: pass a private `--scratch-path` to `swift build` and `swift test`.

## Chromium
- Changes to Chromium live in the patch series in `chromium-patches/`. Follow its README; never edit a `.patch` file by hand.
- Files we add to Chromium start with the header in `chromium-patches/LICENSE-HEADER.txt`.

## Conventions
- All comments and docs are in English.
- One concern per commit. Never force-push.
- See `CONTRIBUTING.md` for bug reports and pull requests.
