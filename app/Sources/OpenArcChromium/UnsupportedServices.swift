import Foundation
import OpenArcModel
import OpenArcEngine

// Extensions of the Chromium engine. The bridge has none yet (OACExtensions.h is a skeleton for
// plan C14): the list stays empty, the stream finishes at once, commands do nothing and installing
// throws `EngineError.unsupported`.

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
