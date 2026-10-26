import Foundation
import OpenArcModel
import OpenArcEngine

// Downloads and extensions of the Chromium engine. The bridge has neither yet (OACDownloads.h and
// OACExtensions.h are skeletons for plans C12 and C14; the content-level embedder installs no
// download manager delegate, so content cancels downloads). Until then both services are empty:
// lists stay empty, streams finish at once, commands do nothing and installing throws
// `EngineError.unsupported`.

/// Empty downloads (plan C12).
final class UnsupportedDownloads: EngineDownloads {
    func items(profileID: Profile.ID) async -> [DownloadItem] { [] }
    func events(profileID: Profile.ID) -> AsyncStream<DownloadEvent> { AsyncStream { $0.finish() } }
    func pause(_ id: String) async {}
    func resume(_ id: String) async {}
    func cancel(_ id: String) async {}
    func confirm(_ id: String, keep: Bool) async {}
    func remove(_ id: String) async {}
    func download(_ url: URL, profileID: Profile.ID) async {}
    func setDefaultDirectory(_ url: URL) async {}
}

/// Empty extensions (plan C14).
final class UnsupportedExtensions: EngineExtensions {
    func installed(profileID: Profile.ID) async -> [EngineExtensionInfo] { [] }
    func actions(for tabID: EngineTabID) async -> [EngineExtensionInfo] { [] }
    func runAction(_ extensionID: String, on tabID: EngineTabID) async {}
    func install(webStoreID: String, profileID: Profile.ID) async throws {
        throw EngineError.unsupported("installExtension")
    }
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async {}
    func uninstall(_ extensionID: String, profileID: Profile.ID) async {}
    func events(profileID: Profile.ID) -> AsyncStream<ExtensionEvent> { AsyncStream { $0.finish() } }
}
