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
        let items = downloads.filtered(by: library.query(for: .downloads))
        if downloads.items.isEmpty, let empty = LibrarySection.downloads.emptyState {
            LibraryEmptyStateView(state: empty, isBoosts: false, palette: palette)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        LibraryDownloadRow(item: item, downloads: downloads, palette: palette)
                    }
                }
            }
            .accessibilityIdentifier("openarc.library.downloads")
        }
    }
}

struct LibraryDownloadRow: View {
    let item: DownloadItem
    let downloads: LibraryDownloads
    let palette: ThemePalette

    var body: some View {
        let presentation = DownloadRowPresentation(item)
        let text = palette.primaryText.swiftUI
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: LibraryLocalTokens.archiveRowIconSize, height: LibraryLocalTokens.archiveRowIconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(Typography.libraryRowTitle.font)
                    .foregroundStyle(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let progress = presentation.progress {
                    ProgressView(value: progress).controlSize(.mini)
                }
                Text(presentation.detail)
                    .font(Typography.libraryRowDetail.font)
                    .foregroundStyle(palette.secondaryText.swiftUI)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            ForEach(presentation.actions, id: \.self) { action in
                button(action, text: text)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: LibraryLocalTokens.archiveRowHeight)
        .contentShape(Rectangle())
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

    private var icon: NSImage {
        if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .data)
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
