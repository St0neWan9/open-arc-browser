# OpenArc: project rules

OpenArc is a clean-room macOS browser. Its interaction and look match Arc one to one; icons and animations may differ. The shell is Swift and SwiftUI and lives in `app/`. The web engine will be a Chromium fork reached through an ObjC++ bridge. Sync uses CloudKit only (CKSyncEngine, private database). AI features are out of scope for v1. The bundle id is the placeholder `org.openarc.browser`, and the minimum OS is macOS 14.

## Clean-room rules
- The only source for behavior and looks is `docs/arc-spec/`.
- **Never read `docs/arc-analysis/`** (it is decompilation background), and do not cite it.
- Never copy Arc internals: no class names, accessibility identifiers or ranking-model names, even where `docs/arc-spec` mentions them. Use our own names.
- Never launch, drive or modify Arc.app. Do not touch `~/chromium` unless your task is the Chromium build.
- Do not install software or kill processes without the user's approval.

## Evidence levels
Every value or behavior taken from the spec carries one of these labels:
- **observed**: measured or seen.
- **inferred**: estimated or derived.
- **unknown**: a placeholder.

Cite the spec section with the label, for example `docs/arc-spec/04-visual-metrics.md §sidebar, observed`. The short form inside code is `[04 §sidebar] observed`.

## Module boundaries (`app/`)
- Dependency direction: `OpenArcModel ← OpenArcEngine / OpenArcSyncAPI / OpenArcDesign ← OpenArcShell ← OpenArcApp`.
- Model imports Foundation only. Engine, SyncAPI and Design import no UI framework.
- Only Shell and App may import SwiftUI or AppKit.
- Every target builds in Swift 6 language mode (`swiftLanguageModes: [.v6]`). Fix concurrency errors with real isolation (`@MainActor`, `Sendable`, `sending`). Each `@unchecked Sendable` or `nonisolated(unsafe)` needs a one-line comment saying why it is safe. Use `@preconcurrency import` only for Apple frameworks.
- CloudKit is imported only by a future sync implementation target, never by SyncAPI.
- The Chromium bridge will be its own target that implements `BrowserEngine`.
- Model and tree changes go through the pure functions in `TreeOps`. They take `now` and new ids as parameters, never call `Date()` or `UUID()`, stamp only the field groups they change, and delete by tombstoning.
- Conflict policy: field-group last-writer-wins, delete wins, ties go to the server (see `OpenArcSyncAPI/ConflictPolicy.swift`). Any new field must join a field group.

## Naming
- Do not give types names that clash with SwiftUI. Use `TabNode`, not `Tab`, and `RGBAColor`, not `Color`. Also avoid `Layout`, `Group`, `Image`, `Window` and `Section`.
- Record type names (`recordTypeName`) and `SyncRecordID.recordName` are persisted. Never rename them.
- Modules are named `OpenArc<Name>`; test targets are `<Module>Tests`.

## Tests
- Every module has a test target.
- New behavior from the spec needs a test that names the spec section.
- Tree operations and the conflict policy must stay covered by tests.
- Tests that read `AsyncStream` must be bounded: take N elements, or use a stream that finishes.
- Before handing off, run `cd app && swift build && swift test`. Both must pass with no warnings.

## Ownership
| Path | Owner | Notes |
|---|---|---|
| `docs/` | spec work (main session) | Read-only for implementation tasks. Never commit or edit it from an implementation task. |
| `app/Sources/<Module>/`, `app/Tests/<Module>Tests/` | the task assigned to that module | Touch only your own module. |
| `app/Package.swift`, protocols, model | Opus (see below) | Changes need review. |
| `~/chromium`, `chromium-patches/` | Chromium build (main session) | |

## Model division and collaboration
1. Division of work:
   - **Opus** owns:
     - the Chromium bridge layer: C++/ObjC++, WebContents, BrowserContext, sandbox, Helper packaging
     - the CloudKit sync layer: CKSyncEngine, conflict merging, encrypted fields
     - architecture decisions
     - splitting `chromium-patches/`
     - review before modules are merged
   - **Sonnet** owns:
     - the SwiftUI UI: sidebar, command bar, popovers
     - design tokens and themes
     - unit tests and scripts
     - matching styles against reference screenshots item by item
2. The main session schedules and merges work, and the Chromium build stays in the main session.
   - Each subagent runs on the model its task specifies (opus or sonnet).
   - Parallel tasks work in disjoint directories (this repo is not a git repository yet, so there are no worktrees). Each task changes only its own module or subfolder, and the main session wires the pieces together.
   - Parallel builds must not share `app/.build`: pass a private `--scratch-path` to `swift build` and `swift test`.
3. Interfaces come before parallel work.
   - Only Opus may change protocols and the model.
   - If a Sonnet task needs a protocol change, it stops and reports instead of making the change.
4. Every Sonnet task must include the matching `docs/arc-spec/` entries as its acceptance criteria. Nobody may read `docs/arc-analysis/` to write an implementation (clean-room).
5. Subagent reports are at most 25 lines: what changed, test results, and the points that need a decision.
6. Before a merge, `swift build` and `swift test` must pass, and Opus must review the change.

## Plan
- Work follows `docs/implementation-plan.md`, task by task. When a task is finished, set its status to `done` in the same change.
- New work not in the plan is added there first, with an ID, owner and acceptance check.

## Conventions
- All comments and docs in this repo are in English.
- Do not commit or push unless the user asks.
