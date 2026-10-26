# app/Vendor: prebuilt binaries

Binaries the Swift package consumes but does not build. Everything here except this README and `.gitignore` is git-ignored.

| Item | Made by | Used by |
|---|---|---|
| `OpenArcCore.xcframework` | `chromium-bridge/build-framework.sh` (plan C8) | the `OpenArcCore` binary target and `OpenArcChromium` in `app/Package.swift` |

## OpenArcCore.xcframework

Our Chromium fork (`~/chromium/src`, branch `openarc/156`, patches in `chromium-patches/`) packaged as `OpenArcCore.framework`: the engine library (all of Chromium linked statically; only the `OAC*` API and `OACChildProcessMain` exported), its headers and module map, `Resources/` (`openarc.pak`, ICU data, V8 snapshot), `Helpers/Open Arc Helper*.app` (the child-process helper apps, plan C10) and `Libraries/` (SwiftShader). macOS arm64; arm64 + x86_64 via `build-framework.sh --universal` once the x86_64 Chromium build exists (plan C10b, deferred).

```sh
chromium-bridge/build-framework.sh             # ninja build + xcframework (long: run in the background)
chromium-bridge/build-framework.sh --no-build  # package what out/Release already has
```

`app/Package.swift` adds `OpenArcCore`, `OpenArcChromium` and `OpenArcChromiumTests` only when `OpenArcCore.xcframework/Info.plist` exists, so a checkout without it builds and tests with `FakeEngine` alone. With it, `scripts/make-app.sh` embeds the framework into `Open Arc.app/Contents/Frameworks/`, and the app uses Chromium when launched with `OPENARC_ENGINE=chromium`.

The framework is about 450 MB; SwiftPM copies it next to the built executable, so a build directory with it is large.
