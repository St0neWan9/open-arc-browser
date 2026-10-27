import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineImporter` on top of the bridge (plan D3b): `-[OACProfile importDataOfTypes:fromSource:…]`
// on the on-disk profile (chromium-bridge/include/OpenArcCore/OACImport.h). Each call hops to the
// main actor; the bridge reads on Chromium's background threads and answers on the main thread.

final class ChromiumImporter: EngineImporter {
    private let core: ChromiumEngineCore

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    var supportedKinds: EngineImportKinds { [.history, .passwords] }

    func importData(_ kinds: EngineImportKinds, from source: EngineImportSource, into profileID: Profile.ID) async -> EngineImportResult {
        guard !kinds.isEmpty else { return EngineImportResult() }
        guard let profile = await core.onDiskProfile(profileID) else { return .all(.unavailable, for: kinds) }
        let result = await Self.run(kinds, source: source, profile: profile)
        return EngineImportResult(
            historyStatus: EngineImportStatus(result.historyStatus), historyCount: result.historyCount,
            passwordStatus: EngineImportStatus(result.passwordStatus), passwordCount: result.passwordCount,
            passwordConflicts: result.passwordConflictCount, passwordFailures: result.passwordFailureCount
        )
    }
}

extension ChromiumImporter {
    @MainActor
    private static func run(_ kinds: EngineImportKinds, source: EngineImportSource, profile: OACProfile) async -> OACImportResult {
        var types: OACImportDataTypes = []
        if kinds.contains(.history) { types.insert(.history) }
        if kinds.contains(.passwords) { types.insert(.passwords) }
        return await profile.importData(ofTypes: types, from: OACImportSource.make(source))
    }
}

extension OACImportSource {
    static func make(_ source: EngineImportSource) -> OACImportSource {
        switch source {
        case .chromiumProfile(let directory, let service, let account):
            return chromiumProfile(at: directory, keychainServiceName: service, keychainAccountName: account)
        case .safari(let libraryDirectory):
            return safari(at: libraryDirectory)
        case .exportFile(let url):
            return exportFile(at: url)
        }
    }
}

extension EngineImportStatus {
    init(_ status: OACImportStatus) {
        switch status {
        case .notRequested: self = .notRequested
        case .success: self = .success
        case .notFound: self = .notFound
        case .permissionDenied: self = .permissionDenied
        case .keychainDenied: self = .keychainDenied
        case .decryptionFailed: self = .decryptionFailed
        case .unreadable: self = .unreadable
        case .unavailable: self = .unavailable
        @unknown default: self = .unreadable
        }
    }
}
