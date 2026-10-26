import SwiftUI
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Preview harness: a sample workspace and a `FakeEngine`, so the sidebar can be inspected without
// the rest of the app. Open this file in Xcode's canvas, or embed `SidebarPreviewHarness` in a
// scratch window.

/// Builds sample data for the sidebar. All ids are random; times are fixed.
@MainActor
public enum SidebarPreviewFixtures {

    /// A workspace with one profile, three spaces (the first has favorites, nested folders,
    /// pinned tabs and Today tabs) and a view model backed by `FakeEngine`.
    public static func makeViewModel(emptySpace: Bool = false) -> SidebarViewModel {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UUID(), home = UUID(), work = UUID(), play = UUID()
        let themeHome = UUID(), themeWork = UUID()
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        s.themes[themeHome] = Theme(id: themeHome, colors: [RGBAColor(hex: 0x8A9BD8)], now: now)
        s.themes[themeWork] = Theme(id: themeWork, colors: [RGBAColor(hex: 0xD8B58A)], now: now)
        do {
            s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", icon: "house", themeID: themeHome, now: now)
            s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", icon: "briefcase", themeID: themeWork, afterSpaceID: home, now: now)
            s = try TreeOps.createSpace(s, id: play, profileID: profile, name: "Play", icon: "🎮", afterSpaceID: work, now: now)
            guard !emptySpace else {
                return SidebarViewModel(engine: FakeEngine(), workspace: s, selectedSpaceID: home, now: { now })
            }
            func tab(_ host: String, _ title: String, _ location: TabLocation) throws {
                let id = UUID()
                s = try TreeOps.openTab(s, id: id, spaceID: home, url: URL(string: "https://\(host)"), title: title, now: now)
                if case .today = location { return }
                s = try TreeOps.moveTab(s, id: id, to: location, position: .last, now: now)
            }
            for (host, title) in [("mail.example.com", "Mail"), ("calendar.example.com", "Calendar"), ("chat.example.com", "Chat")] {
                try tab(host, title, .favorite(profileID: profile))
            }
            let reading = UUID(), nested = UUID()
            s = try TreeOps.createFolder(s, id: reading, spaceID: home, title: "Reading", now: now)
            s = try TreeOps.createFolder(s, id: nested, spaceID: home, parentFolderID: reading, title: "Later", now: now)
            try tab("news.example.com", "News", .pinned(spaceID: home, folderID: reading))
            try tab("blog.example.org", "A very long blog post title that has to be truncated", .pinned(spaceID: home, folderID: nested))
            try tab("docs.example.com", "Docs", .pinned(spaceID: home, folderID: nil))
            for (host, title) in [("example.com", "Example Domain"), ("example.net", "Example Net"), ("example.org", "Example Org")] {
                try tab(host, title, .today(spaceID: home))
            }
        } catch {
            assertionFailure("preview workspace is invalid: \(error)")
        }
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: s, selectedSpaceID: home, now: { now })
        if let first = s.today(spaceID: home).first {
            vm.selectTab(first.id)
        }
        return vm
    }
}

/// Hosts the sidebar at the reference window height next to a stand-in for the web panel.
public struct SidebarPreviewHarness: View {
    @StateObject private var viewModel: SidebarViewModel

    public init(emptySpace: Bool = false) {
        _viewModel = StateObject(wrappedValue: SidebarPreviewFixtures.makeViewModel(emptySpace: emptySpace))
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(viewModel: viewModel)
            Color.white.opacity(0.9)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(Metrics.WebPanel.cornerRadius)))
                .padding(.vertical, CGFloat(Metrics.WebPanel.insetTop))
                .padding(.trailing, CGFloat(Metrics.WebPanel.insetTrailing))
        }
        .frame(width: 700, height: CGFloat(Metrics.referenceWindowSize.height))
    }
}

#if DEBUG
struct SidebarPreviewHarness_Previews: PreviewProvider {
    static var previews: some View {
        SidebarPreviewHarness()
            .previewDisplayName("Sidebar with content")
        SidebarPreviewHarness(emptySpace: true)
            .previewDisplayName("Sidebar, empty space")
    }
}
#endif
