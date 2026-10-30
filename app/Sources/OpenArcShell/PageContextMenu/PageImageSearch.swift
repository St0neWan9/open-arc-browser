import Foundation
import OpenArcModel

// "Search <engine> for Image" in the image right-click menu (plan B139, F5-11). Spec:
// docs/arc-spec/05-surfaces.md §右键菜单 E29 (image), observed: "… Copy Image Address · Search
// Google for Image ‖ Inspect", where "Google" names the profile's search engine.
//
// Arc runs this through Chromium's Lens, which needs a Chrome browser window. We open the
// engine's search-by-image-URL page for the image's source URL in a new tab instead (inferred).
// Engines without a public search-by-URL page leave the item out (see
// `SearchEngine.imageSearchURLTemplate`).

extension SearchEngine {
    /// Search-by-image URL template; `%@` is replaced by the image's escaped source URL. nil when
    /// the engine has no page that takes an image URL, and then the menu leaves the item out.
    /// The endpoints are the engines' public reverse-image pages (inferred; the spec records none):
    /// - Google: `searchbyimage?image_url=` redirects to its image results.
    /// - Bing: Visual Search takes the image URL as `imgurl:`.
    /// - DuckDuckGo, Yahoo, Ecosia: no search by image URL, so no item.
    public var imageSearchURLTemplate: String? {
        switch self {
        case .google: return "https://www.google.com/searchbyimage?image_url=%@"
        case .bing: return "https://www.bing.com/images/search?view=detailv2&iss=sbi&q=imgurl:%@"
        case .duckDuckGo, .yahoo, .ecosia: return nil
        }
    }
}

enum PageImageSearch {
    /// The search page for `imageURL` with `template`, or nil when the image has no web address
    /// (a `data:` or `blob:` image cannot be passed by URL; inferred) or the template is unusable.
    static func url(template: String, imageURL: URL) -> URL? {
        guard let scheme = imageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        // Only RFC 3986 unreserved characters stay as they are: the image URL is one query value.
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        guard let escaped = imageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%@", with: escaped))
    }
}
