import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Small shared pieces: coordinate space, preference key, icons, pasteboard, drop delegates.

enum SidebarCoordinateSpace {
    static let root = "openarc.sidebar.root"
}

/// Row frames in the sidebar's root coordinate space, used to place the hover card.
struct SidebarRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
enum SidebarPasteboard {
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: - Icons

/// Favicon of a tab: PNG data (live engine icon or the favicon cache, C9) if present, else a
/// placeholder.
struct SidebarFaviconView: View {
    /// What stands in for a missing favicon.
    enum Placeholder {
        /// A globe glyph (Library lists; our own look).
        case globe
        /// A rounded square inset 1 pt in the cell (16 × 16 in the 18 pt cell, radius ≈ 3), filled
        /// with `tint`. [07 §4] observed "placeholder icon radius ≈ 3"; round-1 PX (B32) observed
        /// the 16 pt ink.
        case roundedSquare
    }

    let pngData: Data?
    let size: CGFloat
    let tint: Color
    var placeholder: Placeholder = .globe

    var body: some View {
        Group {
            if let image = SidebarFaviconView.image(pngData) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                switch placeholder {
                case .globe:
                    Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(tint)
                case .roundedSquare:
                    RoundedRectangle(cornerRadius: SidebarLocalTokens.faviconPlaceholderCornerRadius, style: .continuous)
                        .fill(tint)
                        .padding(SidebarLocalTokens.faviconPlaceholderInset)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Decoded images by their bytes, so a row does not decode its PNG on every render.
    @MainActor private static var decoded: [Data: NSImage] = [:]

    @MainActor
    static func image(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        if let image = decoded[data] { return image }
        guard let image = NSImage(data: data) else { return nil }
        // Small icons; a few hundred distinct ones at most in practice (inferred). Bounded anyway.
        if decoded.count > 512 { decoded.removeAll() }
        decoded[data] = image
        return image
    }
}

/// Icon of a Space: an emoji, an SF Symbol name, or a default, in a `size` cell. With `glyphSize`
/// the glyph is drawn at that point size, centered in the cell (sidebar header and dock, B33:
/// the reference draws a ≈ 14 pt glyph in its 26 pt header cell); without it, it fills the cell.
struct SidebarSpaceIconView: View {
    let icon: String?
    let size: CGFloat
    var glyphSize: CGFloat? = nil
    let tint: Color

    var body: some View {
        Group {
            if let icon, let first = icon.unicodeScalars.first, !first.isASCII {
                Text(icon).font(.system(size: (glyphSize ?? size) * 0.9))
            } else if let glyphSize {
                Image(systemName: icon ?? "circle.grid.2x2")
                    .font(.system(size: glyphSize, weight: .regular))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: icon ?? "circle.grid.2x2").resizable().scaledToFit().foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Region reporting

/// Frames of the non-row regions (list viewport, divider, "+ New Tab", favorites, dock icons) in the
/// sidebar root coordinate space. Rows report through `SidebarRowFramesKey`.
struct SidebarDropRegionsKey: PreferenceKey {
    static let defaultValue: [SidebarDropRegion: CGRect] = [:]
    static func reduce(value: inout [SidebarDropRegion: CGRect], nextValue: () -> [SidebarDropRegion: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame as a drop region.
    func sidebarDropRegion(_ region: SidebarDropRegion) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDropRegionsKey.self,
                    value: [region: proxy.frame(in: .named(SidebarCoordinateSpace.root))]
                )
            }
        )
    }
}

// MARK: - Drop delegate

/// The one drop delegate of the sidebar. It hit-tests the pointer against the reported frames
/// (`SidebarDropHitTester`, pure and unit-tested) instead of having a delegate per row, so the
/// result does not depend on how SwiftUI routes nested drop targets.
///
/// Accepts in-app drags (`draggingItem` set by the drag source) and links from other apps (URL).
struct SidebarRootDropDelegate: DropDelegate {
    let viewModel: SidebarViewModel
    let geometry: SidebarDropGeometry

    private var isInternal: Bool { viewModel.draggingItem != nil }

    func validateDrop(info: DropInfo) -> Bool {
        isInternal || info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        if !isInternal { viewModel.beginExternalDrag() }
        viewModel.updateDropTarget(at: info.location, in: geometry)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !isInternal { viewModel.beginExternalDrag() }
        let accepted = viewModel.updateDropTarget(at: info.location, in: geometry)
        return DropProposal(operation: accepted ? (isInternal ? .move : .copy) : .forbidden)
    }

    func dropExited(info: DropInfo) {
        viewModel.clearDropTarget()
        // An in-app drag may come back; an external one is over when it leaves.
        if !isInternal { viewModel.endDrag() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = SidebarDropHitTester.target(at: info.location, in: geometry)
        if isInternal {
            guard let target else {
                viewModel.endDrag()
                return false
            }
            return viewModel.performDrop(on: target)
        }
        guard let target, viewModel.dropPlan(for: target) != nil,
              let provider = info.itemProviders(for: [.url]).first else {
            viewModel.endDrag()
            return false
        }
        let model = viewModel
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                if let url { model.performURLDrop(url, on: target) } else { model.endDrag() }
            }
        }
        return true
    }
}

// MARK: - Drag source

/// Drag preview: a lifted white row with the title. Look unknown (the spec does not show a drag
/// image); mirrors the selected-row look. inferred.
struct SidebarDragPreview: View {
    let title: String

    var body: some View {
        Text(title.isEmpty ? "New Tab" : title)
            .font(Typography.tabRowTitle.font)
            .foregroundStyle(RGBAColor(hex: SidebarLocalTokens.cardTextRGB).swiftUI)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: SidebarLocalTokens.hoverCardMaxWidth)
            .frame(height: CGFloat(Metrics.Sidebar.selectedRowHeight))
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Metrics.Sidebar.selectedRowCornerRadius), style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: SidebarLocalTokens.dragPreviewShadowRadius, y: 2)
            )
            .scaleEffect(SidebarLocalTokens.dragPreviewScale)
    }
}

extension View {
    /// Makes a tab or folder draggable. The payload is private to this app (`SidebarDragPayload`);
    /// a tab with a URL can also be dragged out as a link.
    func sidebarDraggable(viewModel: SidebarViewModel, item: SidebarDragItem) -> some View {
        onDrag {
            viewModel.beginDrag(item, isSessionActive: { NSEvent.pressedMouseButtons & 1 != 0 })
            let url: URL? = if case .tab(let id) = item { viewModel.linkURL(for: id) } else { nil }
            return SidebarDragPayload.makeProvider(item: item, url: url)
        } preview: {
            SidebarDragPreview(title: viewModel.dragTitle(for: item))
        }
    }
}

// MARK: - Row interaction (drag source, frame reporting, indicator)

/// Common behavior of tab and folder rows. Drops are handled by the root delegate.
struct SidebarRowInteraction: ViewModifier {
    @ObservedObject var viewModel: SidebarViewModel
    let id: UUID
    let dragItem: SidebarDragItem

    func body(content: Content) -> some View {
        let accent = viewModel.palette.commandBarSelection.swiftUI
        let radius = CGFloat(Metrics.Sidebar.selectedRowCornerRadius)
        let fill = SidebarLayout().rowFillFrame
        content
            // The source row stays in the list, dimmed, while its preview is dragged.
            .opacity(viewModel.draggingItem == dragItem ? SidebarLocalTokens.draggedRowOpacity : 1)
            .overlay(alignment: .top) { line(.above, accent) }
            .overlay(alignment: .bottom) { line(.below, accent) }
            .overlay {
                if viewModel.dropTarget == .row(id, .into) {
                    // Folder that would receive the drop: tinted and outlined. Look unknown.
                    ZStack {
                        RoundedRectangle(cornerRadius: radius).fill(accent.opacity(SidebarLocalTokens.dropIntoFillOpacity))
                        RoundedRectangle(cornerRadius: radius).stroke(accent, lineWidth: SidebarLocalTokens.dropIndicatorThickness)
                    }
                    .frame(width: fill.width, height: fill.height)
                    .allowsHitTesting(false)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarRowFramesKey.self,
                        value: [id: proxy.frame(in: .named(SidebarCoordinateSpace.root))]
                    )
                }
            )
            .sidebarDraggable(viewModel: viewModel, item: dragItem)
    }

    @ViewBuilder
    private func line(_ zone: SidebarDropZone, _ accent: Color) -> some View {
        if viewModel.dropTarget == .row(id, zone) {
            Capsule().fill(accent).frame(height: SidebarLocalTokens.dropIndicatorThickness)
                .padding(.horizontal, SidebarLayout().horizontalInset)
                .offset(y: zone == .above ? -SidebarLocalTokens.dropIndicatorThickness / 2 : SidebarLocalTokens.dropIndicatorThickness / 2)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func sidebarRowInteraction(viewModel: SidebarViewModel, id: UUID, dragItem: SidebarDragItem) -> some View {
        modifier(SidebarRowInteraction(viewModel: viewModel, id: id, dragItem: dragItem))
    }
}

// MARK: - Button style

/// A plain button style that does not dim a disabled label: the label sets its own disabled
/// opacity ([07 §2] ≈ 30 %). `.plain` multiplies a disabled label by about 0.6 on top of that,
/// so the glyph read ≈ 18 % in the round-2 comparison (B33, PX).
struct SidebarUndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
