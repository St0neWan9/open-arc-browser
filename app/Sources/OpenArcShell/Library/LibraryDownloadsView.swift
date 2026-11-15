import SwiftUI
import AppKit
import OpenArcEngine
import OpenArcDesign

// Library ▸ Downloads list (C12). Behavior and texts: LibraryDownloads.swift. The empty state is
// [06 §8] observed; the rows are inferred and follow the Archived Tabs rows.

struct LibraryDownloadsList: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var downloads: LibraryDownloads
    let palette: ThemePalette

    var body: some View {
        let groups = library.downloadGroups
        if downloads.items.isEmpty, let empty = LibrarySection.downloads.emptyState {
            LibraryEmptyStateView(state: empty, isBoosts: false, palette: palette)
        } else {
            // Grouped by age under date headers, as in Arc (B229 observed).
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.age) { group in
                        LibraryListHeader(title: group.age.title, palette: palette)
                        ForEach(group.items) { item in
                            LibraryDownloadRow(item: item, downloads: downloads, palette: palette)
                        }
                    }
                }
            }
            .accessibilityIdentifier("openarc.library.downloads")
        }
    }
}

/// A download's icon: the file's Quick Look thumbnail once the file is there (Arc shows page and
/// image previews, B229 observed), else its Finder icon.
struct LibraryDownloadIcon: View {
    let item: DownloadItem
    @State private var thumbnail: NSImage?

    var body: some View {
        let size = LibraryLocalTokens.downloadIconSize
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: fileURL) {
            guard let fileURL else { thumbnail = nil; return }
            thumbnail = await LibraryMediaThumbnails.shared.thumbnail(for: fileURL, size: CGSize(width: size, height: size))
        }
    }

    private var fileURL: URL? {
        guard item.state == .complete, let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var icon: NSImage {
        if let url = fileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .data)
    }
}

struct LibraryDownloadRow: View {
    let item: DownloadItem
    let downloads: LibraryDownloads
    let palette: ThemePalette

    @State private var isHovering = false

    var body: some View {
        let presentation = DownloadRowPresentation(item)
        let text = palette.primaryText.swiftUI
        LibraryListRowLayout(title: presentation.title, detail: LibraryDownloadList.detail(for: item), palette: palette) {
            LibraryDownloadIcon(item: item)
        } accessory: {
            // A finished file has no buttons (B229, Arc observed; its menu keeps Open and Show in
            // Finder); a running, paused or held one keeps its controls.
            if item.state != .complete {
                HStack(spacing: 6) {
                    ForEach(presentation.actions, id: \.self) { action in
                        button(action, text: text)
                    }
                }
                .fixedSize()
                .padding(.trailing, 6)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress = presentation.progress {
                ProgressView(value: progress)
                    .controlSize(.mini)
                    .padding(.leading, LibraryLocalTokens.listIconColumnWidth + LibraryLocalTokens.listIconTitleGap)
                    .padding(.trailing, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Metrics.Sidebar.selectedRowCornerRadius), style: .continuous)
                .fill(isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if item.state == .complete, let url = item.fileURL { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if item.state == .complete, let url = item.fileURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy Download Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.sourceURL.absoluteString, forType: .string)
            }
            Button("Remove from List") { downloads.remove(item.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.download")
    }

    @ViewBuilder
    private func button(_ action: DownloadRowPresentation.Action, text: Color) -> some View {
        switch action {
        case .keep:
            Button("Keep") { downloads.confirm(item.id, keep: true) }.controlSize(.small)
        case .discard:
            Button("Discard") { downloads.confirm(item.id, keep: false) }.controlSize(.small)
        default:
            Button { perform(action) } label: {
                Image(systemName: symbol(action))
            }
            .buttonStyle(.plain)
            .foregroundStyle(text.opacity(0.7))
            .help(help(action))
        }
    }

    private func perform(_ action: DownloadRowPresentation.Action) {
        switch action {
        case .pause: downloads.pause(item.id)
        case .resume, .retry: downloads.resume(item.id)
        case .cancel: downloads.cancel(item.id)
        case .keep: downloads.confirm(item.id, keep: true)
        case .discard: downloads.confirm(item.id, keep: false)
        case .reveal: if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .remove: downloads.remove(item.id)
        }
    }

    private func symbol(_ action: DownloadRowPresentation.Action) -> String {
        switch action {
        case .pause: "pause.circle"
        case .resume: "play.circle"
        case .retry: "arrow.clockwise.circle"
        case .cancel: "xmark.circle"
        case .reveal: "magnifyingglass.circle"
        case .remove: "trash.circle"
        case .keep, .discard: "exclamationmark.triangle"
        }
    }

    private func help(_ action: DownloadRowPresentation.Action) -> String {
        switch action {
        case .pause: "Pause"
        case .resume: "Resume"
        case .retry: "Retry"
        case .cancel: "Cancel"
        case .reveal: "Show in Finder"
        case .remove: "Remove from List"
        case .keep: "Keep"
        case .discard: "Discard"
        }
    }
}
