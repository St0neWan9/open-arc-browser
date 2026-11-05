# Contributing to Open Arc

Thanks for helping. Please keep changes focused; reviews may take a little time.

## Reporting a bug

Open an [issue](https://github.com/St0neWan9/open-arc-browser/issues) and include:

- the Open Arc version (**Open Arc ▸ About Open Arc**) and your macOS version;
- what you did, what you expected and what happened instead;
- a screenshot or screen recording for anything visual;
- for a crash, the report from **Settings ▸ Advanced ▸ Show Crash Reports in Finder**. Check it for personal data before you attach it.

If the behavior differs from Arc, say what Arc does. That is often the most useful part of the report.

## Suggesting a feature

Open an issue first and describe the use case. Features that Arc never had, or that Open Arc has decided to leave out (see "Not included" in the [README](README.md#not-included)), may be declined.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your change. Keep one concern per pull request.
3. Build and test from `app/`:

   ```sh
   cd app
   swift build
   swift test
   ```

   Both must pass with no warnings. Most interface work runs on `FakeEngine` and needs no Chromium build; see [Build from source](README.md#build-from-source).
4. Open a pull request against `main`. Describe what changed and why, how you tested it, and add before and after screenshots for visual changes.

## Code guidelines

- **Tests:** new behavior needs a test. Tree operations and the sync conflict policy must stay covered. Tests that read an `AsyncStream` must be bounded.
- **Module boundaries:** `OpenArcModel` imports Foundation only. `OpenArcEngine`, `OpenArcSyncAPI` and `OpenArcDesign` import no UI framework. Only `OpenArcShell` and `OpenArcApp` may import SwiftUI or AppKit. See [`app/README.md`](app/README.md) for the dependency graph.
- **Concurrency:** every target builds in Swift 6 language mode. Fix data-race errors with real isolation (`@MainActor`, `Sendable`). Each `@unchecked Sendable` or `nonisolated(unsafe)` needs a one-line comment explaining why it is safe.
- **Model changes:** go through the pure functions in `TreeOps`. They take the time and new ids as parameters and delete by tombstoning. A new synced field must join a field group.
- **Persisted names:** never rename record type names or record names; existing data and sync depend on them.
- **Naming:** avoid type names that clash with SwiftUI (`Tab`, `Color`, `Image`, `Window` and so on).
- **Chromium changes:** go into the patch series. Follow the rules in [`chromium-patches/README.md`](chromium-patches/README.md) and never edit a `.patch` file by hand.
- **Language:** write comments and documentation in English.

## Keeping it original

Open Arc follows Arc's design but is written from scratch. Please do not contribute anything copied from Arc or from The Browser Company: no code, decompiled output, assets, icons, sounds, strings or internal names. Describe behavior in your own words and use our own names.

## License

By contributing, you agree that your contribution is licensed under the [BSD-3-Clause license](LICENSE).
