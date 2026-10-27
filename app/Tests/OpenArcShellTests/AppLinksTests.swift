import Foundation
import XCTest
@testable import OpenArcShell

/// Plan B88 (D13 follow-up, docs/release.md §Network use "Help / homepage links"): every shipped
/// link to the project's pages comes from the one constant set in `MenuBar/AppLinks.swift`.
/// Items: [01 §Arc] Share Arc, Privacy Policy and [01 §Help] Contact the Team, Visit Help Center
/// (observed); Settings ▸ Profiles "Learn more" (B83, inferred target). The host is still a
/// placeholder; that is allowed here, a second spelling of it elsewhere is not.
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
            OpenArcLinks.profilesHelp, OpenArcLinks.contactTheTeam,
        ])
        XCTAssertEqual(Set(OpenArcLinks.all).count, OpenArcLinks.all.count)
        for url in OpenArcLinks.all {
            if url.scheme == "mailto" {
                XCTAssertTrue(url.absoluteString.hasSuffix("@" + OpenArcLinks.siteHost), "\(url)")
            } else {
                XCTAssertEqual(url.scheme, "https", "\(url)")
                XCTAssertEqual(url.host, OpenArcLinks.siteHost, "\(url)")
                XCTAssertTrue(url.absoluteString.hasPrefix(OpenArcLinks.site.absoluteString), "\(url)")
            }
        }
        XCTAssertEqual(OpenArcLinks.homepage, OpenArcLinks.site)
        XCTAssertEqual(OpenArcLinks.privacyPolicy.path, "/privacy")
        XCTAssertEqual(OpenArcLinks.helpCenter.path, "/help")
        XCTAssertEqual(OpenArcLinks.profilesHelp.path, "/help/profiles")
    }

    /// No shipped file other than AppLinks.swift spells out the site host or a URL to the
    /// project's pages. The two feeds on the static host (Sparkle appcast, ad-block manifest) are
    /// not pages and are allowed.
    func testNoOtherFileHardCodesAProjectPageURL() throws {
        let root = repositoryRoot
        let linksFile = root.appendingPathComponent("app/Sources/OpenArcShell/MenuBar/AppLinks.swift").standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: linksFile.path))
        let allowedFeeds = ["openarc.github.io/appcast.xml", "openarc.github.io/adblock/"]
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
                if text.contains(OpenArcLinks.siteHost) {
                    offenders.append("\(file.path): spells out \(OpenArcLinks.siteHost)")
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
