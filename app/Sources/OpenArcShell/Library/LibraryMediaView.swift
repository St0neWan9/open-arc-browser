import SwiftUI
import AppKit
import QuickLookThumbnailing
import OpenArcDesign

// Library ▸ Media list (B57). Behavior: LibraryMedia.swift. [06 §8] observed: thumbnail rows in
// date groups (Today / Yesterday / Earlier This Week) under "Search Media…"; row layout, click and
// context menu inferred (they follow the Archived Tabs and Downloads rows).

struct LibraryMediaList: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var media: LibraryMediaModel
    let palette: ThemePalette

    var body: some View {
        let page = library.mediaPage
        let text = palette.primaryText.swiftUI
        if !media.hasLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24)
        } else if page.groups.isEmpty {
            Text(media.items.isEmpty ? LibraryTexts.mediaEmpty : LibraryTexts.mediaNoMatches)
                .font(Typography.libraryEmptyDetail.font)
                .foregroundStyle(Typography.libraryEmptyDetail.color(palette.chromeInk))
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .accessibilityIdentifier("openarc.library.media.empty")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(page.groups, id: \.group) { group in
                        Text(group.group.title)
                            .textStyle(Typography.libraryGroupHeader, ink: palette.chromeInk)
                            .padding(.top, 6)
                        ForEach(group.items) { item in
                            LibraryMediaRow(item: item, textColor: text, secondary: palette.secondaryText.swiftUI) {
                                library.openMedia(item)
                            }
                        }
                    }
                    if page.hasMore {
                        // Next page when the end of the list comes on screen.
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .onAppear { media.showMore() }
                    }
                }
            }
            .accessibilityIdentifier("openarc.library.media")
        }
    }
}

struct LibraryMediaRow: View {
    let item: LibraryMediaItem
    let textColor: Color
    let secondary: Color
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            LibraryMediaThumbnail(url: item.url, kind: item.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Typography.libraryRowTitle.font)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(Typography.libraryRowDetail.font)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: CGFloat(Metrics.Library.mediaRowHeight))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Metrics.Sidebar.selectedRowCornerRadius), style: .continuous)
                .fill(isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onOpen)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Open with Default App") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy") { LibraryMediaPasteboard.copy(item.url) }
            Button("Copy Path") { LibraryMediaPasteboard.copyPath(item.url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("openarc.library.media.row")
    }
}

/// "Copy" puts the file itself on the pasteboard (pastes as the file in Finder, Mail, chat apps),
/// like Finder's Copy. inferred.
enum LibraryMediaPasteboard {
    static func copy(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    static func copyPath(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url.path, forType: .string)
    }
}

/// Quick Look thumbnail of a file (falls back to its Finder icon). Cached for the app's life.
struct LibraryMediaThumbnail: View {
    let url: URL
    let kind: LibraryMediaKind

    @State private var image: NSImage?

    var body: some View {
        let size = Metrics.Library.mediaThumbnailSize
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
        }
        .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(Metrics.Library.mediaThumbnailCornerRadius), style: .continuous))
        .task(id: url) {
            image = await LibraryMediaThumbnails.shared.thumbnail(for: url, size: CGSize(width: size.width, height: size.height))
        }
    }
}

/// Quick Look thumbnails, cached by file and modification date.
@MainActor
final class LibraryMediaThumbnails {
    static let shared = LibraryMediaThumbnails()

    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 500 }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}
