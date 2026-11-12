import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The hovered link's address at the web panel's bottom left (plan B218). [06 §44] observed:
// a pill 10 pt from the panel's left and bottom edges, the address without its scheme, cut in the
// middle past ≈ 400 pt, a quick fade in and no fade out; after 1 s on one link the whole address
// shows (B219). Each page view shows its own tab's link,
// so split panes, Peek and Little Arc get theirs too (inferred).

/// What the pill reads for a link. Pure, for tests.
enum LinkStatusText {
    /// `https://example.org/` → `example.org`; `http://` goes too ([06 §44] observed). Path, query
    /// and fragment stay. Other schemes (`mailto:`, `file:`) show in full (inferred).
    static func display(_ url: URL) -> String {
        var text = url.absoluteString
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return text }
        let prefix = scheme + "://"
        if text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        // Only a bare trailing slash goes (observed for a site root; a deeper path is inferred).
        if text.hasSuffix("/"), url.query == nil, url.fragment == nil { text.removeLast() }
        return text
    }
}

/// Watches `tab` for the link under the pointer and shows its address. Transparent to the mouse,
/// so the pill never takes the hover away from the page.
struct LinkStatusBubble: View {
    let tab: any BrowserTab
    let palette: ThemePalette?
    @State private var url: URL?
    /// The pill has shown `url` for `LinkStatusTokens.expandDelay`: no 400 pt limit (B219).
    @State private var isExpanded = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                if let url {
                    pill(LinkStatusText.display(url), panelWidth: proxy.size.width)
                        .transition(.asymmetric(insertion: .opacity.animation(ShellMotion.linkStatusFadeIn), removal: .identity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            isExpanded = false
            guard url != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(LinkStatusTokens.expandDelay * 1_000_000_000))
            if !Task.isCancelled { isExpanded = true }
        }
        .task(id: tab.id) {
            url = nil
            for await event in tab.events() {
                if case .hoveredLinkChanged(let link) = event, link != url { url = link }
            }
        }
    }

    private func pill(_ text: String, panelWidth: CGFloat) -> some View {
        let t = LinkStatusTokens.self
        let colors = t.colors(windowBackground: palette?.windowBackground ?? RGBAColor(hex: 0xFFFFFF),
                              isDark: palette?.isDark ?? false)
        let padding = CGFloat(t.horizontalPadding), inset = CGFloat(t.inset)
        let limit = isExpanded ? panelWidth - 2 * inset : min(CGFloat(t.maxWidth), panelWidth - 2 * inset)
        let widest = max(0, limit - 2 * padding)
        let shape = Capsule(style: .continuous)
        return Text(text)
            .font(.system(size: CGFloat(t.fontSize), weight: .medium))
            .foregroundStyle(colors.text.swiftUI)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: min(Self.textWidth(text), widest), alignment: .leading)
            .padding(.horizontal, padding)
            .frame(height: CGFloat(t.height))
            .background(shape.fill(colors.fill.swiftUI))
            .overlay(shape.strokeBorder(colors.border.swiftUI, lineWidth: CGFloat(t.borderWidth)))
            .shadow(color: .black.opacity(t.shadowOpacity), radius: CGFloat(t.shadowRadius))
            .padding(.leading, inset)
            .padding(.bottom, inset)
    }

    /// Natural width of `text` in the pill's font.
    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(LinkStatusTokens.fontSize), weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
