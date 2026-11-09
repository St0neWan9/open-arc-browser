import Foundation
import OpenArcModel
import OpenArcEngine

// Which link clicks open Peek, and where an intercepted click goes (plan B49).
//
// Spec: [06 §22.1] observed:
//   - favorite: a plain click on a link to another site opens Peek; a same-site link navigates
//     the favorite itself. Pinned tabs do the same (inferred from [06 §16.1] and the Settings
//     note "This only affects Favorites and Pinned tabs", [06 §25.1] / [03 §Links] observed).
//   - Today tab: a plain click navigates in place; a Shift-click opens Peek.
//   - ⌘-click opens a background tab at the top of Today (unchanged, C7b).
// [03 §Links] observed the two switches (`AppPreferences.opensPeekOnShiftClick`,
// `opensPeekForOtherSites`); a switch that is off leaves the click to the engine as before
// (Shift-click: a new window, [06 §4]).
//
// The engine drops the click before it navigates (`BrowserTab.setLinkPreviewTriggers`) and
// reports `TabEvent.linkPreviewRequested`; the window that shows the tab opens Peek over it.
//
// B196: a page in a favorite or pinned tab that opens another site in a new tab (a
// `target=_blank` link, `window.open` without window features) opens it in Peek too, instead of a
// Today tab. inferred: the same "links to other sites, Favorites and Pinned tabs only" switch; the
// spec has not captured these in Arc ([06 §22.5]). Popups with window features (sign-in windows)
// and ⌘-clicks keep their own handling.

/// Triggers last sent per engine tab (a model tab may get a new engine tab). One per
/// `WorkspaceController`.
@MainActor
final class LinkPeekRouting {
    var sent: [EngineTabID: LinkPreviewTriggers] = [:]
}

extension WorkspaceController {
    /// The clicks a tab at `location` intercepts with the given switches. [06 §22.1] observed.
    nonisolated static func linkPreviewTriggers(
        for location: TabLocation, shiftClick: Bool, otherSites: Bool
    ) -> LinkPreviewTriggers {
        var triggers: LinkPreviewTriggers = []
        if shiftClick { triggers.insert(.shiftClick) }
        switch location {
        case .favorite, .pinned:
            if otherSites { triggers.insert(.otherSiteLink) }
        case .today:
            break
        }
        return triggers
    }

    /// The triggers model tab `id` should have now.
    func linkPreviewTriggers(forTab id: UUID) -> LinkPreviewTriggers {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return [] }
        let preferences = dependencies.preferences
        return Self.linkPreviewTriggers(
            for: tab.location,
            shiftClick: preferences.opensPeekOnShiftClick,
            otherSites: preferences.opensPeekForOtherSites
        )
    }

    /// Sends every live tab whose triggers changed its new triggers (a tab was pinned or
    /// unpinned, a switch changed).
    func syncLinkPreviewTriggers() {
        for entry in liveTabEntries { syncLinkPreviewTriggers(of: entry.id) }
        let live = Set(liveTabEntries.map(\.tab.id))
        linkPeekRouting.sent = linkPeekRouting.sent.filter { live.contains($0.key) }
    }

    /// Sends `id`'s engine tab its triggers if they differ from the last ones sent.
    func syncLinkPreviewTriggers(of id: UUID) {
        guard let live = liveTab(for: id) else { return }
        let triggers = linkPreviewTriggers(forTab: id)
        guard linkPeekRouting.sent[live.id] != triggers else { return }
        linkPeekRouting.sent[live.id] = triggers
        enqueueTabCommand(live) { await $0.setLinkPreviewTriggers(triggers) }
    }

    /// Model tab `id`'s engine tab dropped a click for Peek: the window that shows the tab opens
    /// it. A tab on no screen loads the link itself (inferred: the click is not lost).
    func linkPreviewRequested(_ request: LinkPreviewRequest, from id: UUID) {
        if let window = browserWindows.first(where: { $0.sidebar.countsAsVisibleWindow && $0.sidebar.onScreenTabIDs.contains(id) }) {
            window.linkPeek.open(request.url, from: id)
            return
        }
        guard let live = liveTab(for: id) else { return }
        let url = request.url
        enqueueTabCommand(live) { try? await $0.load(url) }
    }

    /// Opens a page's new-tab request in Peek when it comes from a favorite or pinned tab and goes
    /// to another site (B196, see the file header). Returns whether Peek took it; the caller then
    /// drops the engine's pending tab.
    func openNewTabRequestInLinkPeek(_ request: NewTabRequest, opener openerTabID: UUID) -> Bool {
        guard request.disposition == .foregroundTab, request.hasUserGesture,
              dependencies.preferences.opensPeekForOtherSites,
              let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let tab = workspace.tabs[openerTabID], !tab.meta.isTombstone else { return false }
        switch tab.location {
        case .favorite, .pinned: break
        case .today: return false
        }
        // The page the tab shows now, not the address it was pinned with.
        if let current = liveState(for: openerTabID)?.url ?? tab.url,
           LinkPreviewTriggers.isSameSite(current, request.url) { return false }
        guard let window = browserWindows.first(where: {
            $0.sidebar.countsAsVisibleWindow && $0.sidebar.onScreenTabIDs.contains(openerTabID)
        }) else { return false }
        window.linkPeek.open(request.url, from: openerTabID)
        return true
    }

    /// A tab request from a Peek page, which has no model tab: handled as if the Peek's source tab
    /// asked (inferred). Returns false when no Peek owns the opener.
    func handleLinkPeekNewTabRequest(_ request: NewTabRequest) -> Bool {
        guard let opener = request.opener,
              let window = browserWindows.first(where: { $0.linkPeek.session?.tab == opener }),
              let source = window.linkPeek.session?.sourceTabID else { return false }
        var forwarded = request
        forwarded.opener = liveTab(for: source)?.id
        handleNewTabRequest(forwarded)
        return true
    }
}
