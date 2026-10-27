import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// MARK: - Translation (plan B47)

/// `EngineTranslation` on top of the bridge: `OACApplication.translationTargetLanguages` and
/// `-[OACProfile resetTranslationSettings]` (OACTranslation.h).
final class ChromiumTranslation: EngineTranslation {
    private let core: ChromiumEngineCore

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    func targetLanguages() async -> [TranslationLanguage] {
        await MainActor.run {
            ((try? core.ensureStarted())?.translationTargetLanguages ?? []).map(TranslationLanguage.init)
        }
    }

    func resetDecisions(profileID: Profile.ID) async {
        guard let profile = await core.onDiskProfile(profileID) else { return }
        await MainActor.run { profile.resetTranslationSettings() }
    }
}
