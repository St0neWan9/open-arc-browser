import Foundation
import OpenArcEngine
import OpenArcCore

// MARK: - Link preview (plan B49, Peek)

// `BrowserTab.setLinkPreviewTriggers` and `TabEvent.linkPreviewRequested` on top of the bridge's
// `OACTab.linkPreviewTriggers` and `OACLinkPreviewDelegate` (OACLinkPreview.h).

extension ChromiumTab {
    public func setLinkPreviewTriggers(_ triggers: LinkPreviewTriggers) async {
        await core.perform { $0.linkPreviewTriggers = OACLinkPreviewTriggers(triggers) }
    }
}

extension ChromiumTabCore: OACLinkPreviewDelegate {
    func tab(_ tab: OACTab, didInterceptLinkTo url: URL, trigger: OACLinkPreviewTriggers) {
        channel.send(.linkPreviewRequested(LinkPreviewRequest(url: url, trigger: LinkPreviewTriggers(trigger))))
    }
}

extension OACLinkPreviewTriggers {
    init(_ triggers: LinkPreviewTriggers) {
        // Same bit values on both sides (OACLinkPreview.h).
        self.init(rawValue: UInt(triggers.rawValue))
    }
}

extension LinkPreviewTriggers {
    init(_ triggers: OACLinkPreviewTriggers) {
        self.init(rawValue: Int(triggers.rawValue))
    }
}
