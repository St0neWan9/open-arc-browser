import SwiftUI
import AppKit
import OpenArcDesign

// The About window: icon, name, version, engine version, copyright and credits, in the order and
// about the size of Arc's. Observed on a user's 2× screenshot (B173); the wording of the last two
// lines is our own.

/// What the About window says.
struct AboutInfo: Equatable {
    var appName: String
    var version: String
    var build: String
    /// `BrowserEngine.engineVersion`: "Chromium 157.0.8103.39", or another engine's name.
    var engineVersion: String
    var year: Int

    init(appName: String, version: String, build: String, engineVersion: String, year: Int) {
        self.appName = appName
        self.version = version
        self.build = build
        self.engineVersion = engineVersion
        self.year = year
    }

    init(bundle: Bundle = .main, engineVersion: String, now: Date = Date()) {
        let info = bundle.infoDictionary ?? [:]
        self.init(appName: info["CFBundleName"] as? String ?? "Open Arc",
                  version: info["CFBundleShortVersionString"] as? String ?? "",
                  build: info["CFBundleVersion"] as? String ?? "",
                  engineVersion: engineVersion,
                  year: Calendar(identifier: .gregorian).component(.year, from: now))
    }

    var versionLine: String { "Version \(version) (\(build))" }

    var engineLine: String {
        let chromium = "Chromium "
        guard engineVersion.hasPrefix(chromium) else { return engineVersion }
        return "Chromium Engine Version \(engineVersion.dropFirst(chromium.count))"
    }

    var copyrightLine: String { "Copyright © \(year) The Open Arc Authors." }

    /// The credits sentence with its three links.
    var credits: AttributedString {
        func link(_ text: String, _ url: URL) -> AttributedString {
            var part = AttributedString(text)
            part.link = url
            part.underlineStyle = .single
            return part
        }
        return AttributedString("\(appName) is made possible by the ")
            + link("Chromium", AboutLinks.chromium)
            + AttributedString(" open source project, Chromium's ")
            + link("open source software", AboutLinks.chromiumCredits)
            + AttributedString(", as well as other ")
            + link("open source software", AboutLinks.otherCredits)
            + AttributedString(".")
    }
}

enum AboutLinks {
    static let chromium = URL(string: "https://www.chromium.org/")!
    static let chromiumCredits = URL(string: "chrome://credits/")!
    /// Sparkle is the one package the app adds to Chromium.
    static let otherCredits = URL(string: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE")!
}

/// Sizes of the About window. Observed on a user's 2× screenshot (B173).
enum AboutTokens {
    static let windowSize = CGSize(width: 360, height: 232)
    static let iconSize: CGFloat = 52
    static let bodySize: CGFloat = 12
    static let nameSize: CGFloat = 13
}

struct AboutView: View {
    let info: AboutInfo
    let openLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: AboutTokens.iconSize, height: AboutTokens.iconSize)
                .accessibilityHidden(true)
            Text(info.appName)
                .font(.system(size: AboutTokens.nameSize, weight: .bold))
                .padding(.top, 10)
            VStack(spacing: 1) {
                Text(info.versionLine)
                Text(info.engineLine)
            }
            .padding(.top, 8)
            Text(info.copyrightLine).padding(.top, 8)
            Text(info.credits)
                .padding(.top, 8)
                .environment(\.openURL, OpenURLAction { url in
                    openLink(url)
                    return .handled
                })
        }
        .font(.system(size: AboutTokens.bodySize))
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(.horizontal, 20)
        .frame(width: AboutTokens.windowSize.width, height: AboutTokens.windowSize.height)
        .accessibilityIdentifier("openarc.about")
    }
}

/// One About window for the app, brought forward when it is already open.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show(info: AboutInfo, openLink: @escaping (URL) -> Void) {
        if window == nil {
            let new = NSWindow(contentRect: CGRect(origin: .zero, size: AboutTokens.windowSize),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            new.isReleasedWhenClosed = false
            new.titlebarSeparatorStyle = .line
            new.center()
            window = new
        }
        window?.title = "About \(info.appName)"
        window?.titleVisibility = .hidden
        window?.contentView = NSHostingView(rootView: AboutView(info: info, openLink: openLink))
        window?.makeKeyAndOrderFront(nil)
    }
}
