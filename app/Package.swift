// swift-tools-version: 6.0
// Swift package for the OpenArc shell.
// Dependency direction (arrows point only leftwards): Model ← Engine / SyncAPI / Design ← Shell ← App
// Model depends on no other module and never imports SwiftUI / AppKit / CloudKit.

import PackageDescription
import Foundation

// The Chromium engine (plan C8) is built only when chromium-bridge/build-framework.sh has put
// OpenArcCore.xcframework into app/Vendor/ (git-ignored, ~450 MB). Without it the package builds
// exactly as before: FakeEngine only, and OpenArcApp compiles its Chromium code out
// (`#if canImport(OpenArcChromium)`).
let openArcCoreXCFramework = "Vendor/OpenArcCore.xcframework"
let hasChromium = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/" + openArcCoreXCFramework + "/Info.plist"
)

/// Targets that exist only with the xcframework.
let chromiumTargets: [Target] = hasChromium ? [
    // OpenArcCore.framework: our Chromium fork behind its Objective-C API (chromium-bridge/).
    .binaryTarget(name: "OpenArcCore", path: openArcCoreXCFramework),
    // `BrowserEngine` on top of OpenArcCore. The only Swift target that sees an OAC* type.
    // No UI framework: the page's NSView passes through as `AnyObject`.
    .target(name: "OpenArcChromium", dependencies: ["OpenArcEngine", "OpenArcModel", "OpenArcCore"]),
    // Conformance test against the real engine; runs only with OPENARC_ENGINE_TESTS=1.
    .testTarget(name: "OpenArcChromiumTests", dependencies: ["OpenArcChromium"]),
] : []

let package = Package(
    name: "OpenArc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenArcModel", targets: ["OpenArcModel"]),
        .library(name: "OpenArcEngine", targets: ["OpenArcEngine"]),
        .library(name: "OpenArcSyncAPI", targets: ["OpenArcSyncAPI"]),
        .library(name: "OpenArcDesign", targets: ["OpenArcDesign"]),
        .library(name: "OpenArcPersistence", targets: ["OpenArcPersistence"]),
        .library(name: "OpenArcImport", targets: ["OpenArcImport"]),
        .library(name: "OpenArcShell", targets: ["OpenArcShell"]),
        .executable(name: "OpenArcApp", targets: ["OpenArcApp"]),
    ],
    dependencies: [
        // Sparkle 2 (software updates, plan D7). Used by OpenArcApp only; the shell sees the
        // `UpdateChecker` protocol. Pinned to an exact release; bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure data model and tree operations. Must not import SwiftUI / AppKit / CloudKit.
        .target(name: "OpenArcModel"),
        // Engine capability protocols + FakeEngine. No UI framework dependency.
        .target(name: "OpenArcEngine", dependencies: ["OpenArcModel"]),
        // Sync protocols and types only. Does not import CloudKit (the implementation will live in a separate target).
        .target(name: "OpenArcSyncAPI", dependencies: ["OpenArcModel"]),
        // Design tokens and theme derivation. No UI framework; colors are plain numbers.
        .target(name: "OpenArcDesign", dependencies: ["OpenArcModel"]),
        // Local persistence: workspace JSON on disk + SyncLocalDatabase. Foundation only, no UI framework.
        .target(
            name: "OpenArcPersistence",
            dependencies: ["OpenArcModel", "OpenArcSyncAPI"]
        ),
        // Bookmark import from other browsers (Chromium JSON, Netscape HTML, Safari plist) and the
        // mapping onto TreeOps. Foundation only, no UI framework.
        .target(name: "OpenArcImport", dependencies: ["OpenArcModel"]),
        // SwiftUI shell: main window layout placeholder + dependency injection entry point.
        .target(
            name: "OpenArcShell",
            dependencies: ["OpenArcModel", "OpenArcEngine", "OpenArcSyncAPI", "OpenArcDesign", "OpenArcPersistence", "OpenArcImport"]
        ),
        // Executable entry point; contains only @main. It links the CloudKit target so the
        // `OPENARC_SYNC=cloudkit` launch switch can construct the CloudKit store (D5); the shell
        // only sees `SyncStore`.
        // It also links Sparkle (D7) and provides the Sparkle-backed `UpdateChecker`; no other
        // target imports Sparkle. With the xcframework it links OpenArcChromium too, for the
        // `OPENARC_ENGINE=chromium` launch switch (C8); the shell only sees `BrowserEngine`.
        .executableTarget(
            name: "OpenArcApp",
            dependencies: [
                "OpenArcShell",
                "OpenArcSyncCloudKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ] + (hasChromium ? ["OpenArcChromium"] : [])
        ),
        // CloudKit implementation of SyncStore (CKSyncEngine, private database). The only target that imports CloudKit.
        .target(
            name: "OpenArcSyncCloudKit",
            dependencies: ["OpenArcSyncAPI", "OpenArcModel"]
        ),

        .testTarget(name: "OpenArcSyncCloudKitTests", dependencies: ["OpenArcSyncCloudKit"]),
        .testTarget(name: "OpenArcModelTests", dependencies: ["OpenArcModel"]),
        .testTarget(name: "OpenArcEngineTests", dependencies: ["OpenArcEngine"]),
        .testTarget(name: "OpenArcSyncAPITests", dependencies: ["OpenArcSyncAPI"]),
        .testTarget(name: "OpenArcDesignTests", dependencies: ["OpenArcDesign"]),
        .testTarget(name: "OpenArcPersistenceTests", dependencies: ["OpenArcPersistence"]),
        .testTarget(name: "OpenArcImportTests", dependencies: ["OpenArcImport"]),
        .testTarget(name: "OpenArcShellTests", dependencies: ["OpenArcShell"]),
    ] + chromiumTargets,
    // Every target uses Swift 6 language mode (complete strict concurrency checking, errors not warnings).
    swiftLanguageModes: [.v6]
)
