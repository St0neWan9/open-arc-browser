import Foundation
import XCTest
@testable import OpenArcShell

/// Plan B88 (D13 follow-up, docs/release.md §Network use "Help / homepage links"): every shipped
/// link to the project's pages comes from the one constant set in `MenuBar/AppLinks.swift`.
/// Items: [01 §Arc] Share Arc, Privacy Policy and [01 §Help] Contact the Team, Visit Help Center
/// (observed); Settings ▸ Profiles "Learn more" (B83, inferred target). The pages are the public
/// repository's (B113); a second spelling of a page URL elsewhere is not allowed.
final class AppLinksTests: XCTestCase {
    /// The worktree root (`app/..`).
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryLinkIsBuiltFromTheSiteConstant() {
        XCTAssertEqual(OpenArcLinks.all, [
            OpenArcLinks.homepage, OpenArcLinks.privacyPolicy, OpenArcLinks.helpCenter,
            OpenArcLinks.profilesHelp, OpenArcLinks.contactTheTeam, OpenArcLinks.organizingTips,
        ])
        XCTAssertEqual(Set(OpenArcLinks.all).count, OpenArcLinks.all.count)
        for url in OpenArcLinks.all {
            XCTAssertEqual(url.scheme, "https", "\(url)")
            XCTAssertEqual(url.host, OpenArcLinks.siteHost, "\(url)")
            XCTAssertTrue(url.absoluteString.hasPrefix(OpenArcLinks.site.absoluteString), "\(url)")
            XCTAssertFalse(url.absoluteString.contains(".example"), "no placeholder host: \(url)")
        }
        let pages = "/\(OpenArcLinks.repository)/blob/updates/pages/"
        XCTAssertEqual(OpenArcLinks.homepage.path, pages + "README.md")
        XCTAssertEqual(OpenArcLinks.privacyPolicy.path, pages + "privacy.md")
        XCTAssertEqual(OpenArcLinks.helpCenter.path, pages + "help/README.md")
        XCTAssertEqual(OpenArcLinks.profilesHelp.path, pages + "help/profiles.md")
        // B133: the incognito bar's "Tips for Organizing" row ([06 §20.1] observed row, our page).
        XCTAssertEqual(OpenArcLinks.organizingTips.path, pages + "help/organizing.md")
        XCTAssertEqual(OpenArcLinks.contactTheTeam.path, "/\(OpenArcLinks.repository)/issues")
    }

    /// No shipped file other than AppLinks.swift spells out the site host or a URL to the
    /// project's pages. The two feeds on the static host (Sparkle appcast, ad-block manifest) are
    /// not pages and are allowed.
    func testNoOtherFileHardCodesAProjectPageURL() throws {
        let root = repositoryRoot
        let linksFile = root.appendingPathComponent("app/Sources/OpenArcShell/MenuBar/AppLinks.swift").standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: linksFile.path))
        let allowedFeeds = ["openarc.github.io/appcast.xml", "openarc.github.io/adblock/"]  // test fixtures only; the real feeds live on raw.githubusercontent.com (D14)
        let pattern = try NSRegularExpression(pattern: #"(?:https?://|mailto:[^@\s"]*@)(openarc\.[A-Za-z0-9.-]+)([^\s"'<>)]*)"#)

        var offenders: [String] = []
        var scanned = 0
        for directory in ["app/Sources", "app/Bundle", "scripts", "chromium-bridge"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files {
                guard ["swift", "plist", "sh", "html", "js", "json", "m", "mm", "h", "py"].contains(file.pathExtension),
                      file.standardizedFileURL != linksFile,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                if text.contains(OpenArcLinks.site.absoluteString + "/blob/updates/pages")
                    || text.contains(OpenArcLinks.site.absoluteString + "/issues") {
                    offenders.append("\(file.path): spells out a project page URL")
                }
                let range = NSRange(text.startIndex..., in: text)
                for match in pattern.matches(in: text, range: range) {
                    let found = String(text[Range(match.range, in: text)!])
                    if allowedFeeds.contains(where: { found.contains($0) }) { continue }
                    offenders.append("\(file.path): \(found)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found the sources")
        XCTAssertEqual(offenders, [], "use OpenArcLinks in MenuBar/AppLinks.swift")
    }
}
