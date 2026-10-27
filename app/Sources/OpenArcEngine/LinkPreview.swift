import Foundation

// Link clicks the shell previews instead of letting the tab navigate (plan B49, Peek).
//
// Spec: [06 §22.1] observed: in a favorite (and, inferred from [06 §16.1], a pinned tab) a plain
// click on a link to another site opens Peek, while a same-site link navigates the favorite
// itself; in a Today tab a plain click navigates and a Shift-click opens Peek; ⌘-click opens a
// background tab. [03 §Links] observed the two Peek switches ("Shift-click a link" and "links to
// other sites, Favorites and Pinned tabs only").
//
// The shell tells each tab which clicks to intercept (`BrowserTab.setLinkPreviewTriggers`). The
// engine decides before the navigation starts, drops the click (the page stays as it was) and
// reports it as `TabEvent.linkPreviewRequested`. Bridge: `OACLinkPreview.h`.

/// Which link clicks a tab intercepts. Bridge: `OACLinkPreviewTriggers` (same bits).
public struct LinkPreviewTriggers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A plain click on an http(s) link to another site (registrable domain) that would navigate
    /// the tab itself. Scripted navigations, form posts and links in subframes are not
    /// intercepted (inferred).
    public static let otherSiteLink = LinkPreviewTriggers(rawValue: 1 << 0)
    /// A Shift-click on an http(s) link (otherwise a new-window request).
    public static let shiftClick = LinkPreviewTriggers(rawValue: 1 << 1)
}

/// A link click the tab dropped for the shell to preview.
public struct LinkPreviewRequest: Hashable, Sendable {
    public var url: URL
    /// The single trigger that matched.
    public var trigger: LinkPreviewTriggers

    public init(url: URL, trigger: LinkPreviewTriggers) {
        self.url = url
        self.trigger = trigger
    }
}

extension LinkPreviewTriggers {
    /// Whether `a` and `b` are on the same site for the other-site trigger: the same registrable
    /// domain, approximated as the last two host labels (three when the second-to-last label is a
    /// short second-level label such as `co.uk`). The Chromium engine uses the public suffix list;
    /// this approximation serves FakeEngine and tests. URLs without a host are never the same site.
    public static func isSameSite(_ a: URL, _ b: URL) -> Bool {
        guard let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased(), !hostA.isEmpty, !hostB.isEmpty else {
            return false
        }
        return registrableDomain(hostA) == registrableDomain(hostB)
    }

    private static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let secondLevel = labels[labels.count - 2]
        let keep = secondLevel.count <= 3 && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}
