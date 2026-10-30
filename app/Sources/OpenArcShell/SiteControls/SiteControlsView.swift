import SwiftUI
import AppKit
import OpenArcEngine
import OpenArcDesign

// Views of the Site Control Center and the URL box accessories it anchors to. [06 §12] observed
// layout; sizes are local tokens (see SiteControlsTokens.swift).

private struct SiteControlsModelKey: EnvironmentKey {
    static let defaultValue: SiteControlsModel? = nil
}

extension EnvironmentValues {
    /// The window's Site Control Center. nil in previews of the bare sidebar: the URL box then
    /// falls back to copying with the system pasteboard and sends the site-controls request.
    var siteControlsModel: SiteControlsModel? {
        get { self[SiteControlsModelKey.self] }
        set { self[SiteControlsModelKey.self] = newValue }
    }
}

/// The two icons at the right end of the URL box: copy link (chain) and site controls (sliders),
/// each a 30 × 30 `URLBoxIconButton`. Site controls sits at window x 234–264, y 49–79, so the
/// bubble's arrow points at its center and the bubble top lands 12 pt below it (y 91). [07 §12]
/// observed. They show while the box is hovered, and stay while the bubble is open so it keeps its
/// anchor. [06 §12] observed. Without a model (previews of the bare sidebar) copy link uses
/// `copyFallback` and no bubble is anchored.
struct SiteControlsURLBoxAccessories: View {
    let model: SiteControlsModel?
    let isHovering: Bool
    let tint: Color
    /// Palette of the window: the bubble takes its floating-panel tint. [07 §12] observed.
    let chrome: ThemePalette
    let copyFallback: () -> Void
    let openSiteControls: () -> Void

    var body: some View {
        if let model {
            ModelBacked(model: model, isHovering: isHovering, tint: tint, chrome: chrome, openSiteControls: openSiteControls)
        } else if isHovering {
            URLBoxIconRow {
                URLBoxIconButton(symbol: "link", label: "Copy link", id: URLBoxIconButton.copyLinkID, tint: tint,
                                 action: copyFallback)
                    .help("Copy Link")
            } siteControls: {
                URLBoxIconButton(symbol: "slider.horizontal.3", label: "Site controls", id: URLBoxIconButton.siteControlsID,
                                 tint: tint, action: openSiteControls)
            }
        }
    }

    private struct ModelBacked: View {
        @ObservedObject var model: SiteControlsModel
        let isHovering: Bool
        let tint: Color
        let chrome: ThemePalette
        let openSiteControls: () -> Void

        var body: some View {
            if isHovering || model.isPresented || model.isLinkCopied || model.extensionPopup != nil {
                URLBoxIconRow {
                    URLBoxIconButton(symbol: model.isLinkCopied ? "checkmark" : "link",
                                     label: model.isLinkCopied ? "Copied" : "Copy link",
                                     id: URLBoxIconButton.copyLinkID, tint: tint) {
                        model.copyLink()
                    }
                    .help(model.isLinkCopied ? "Copied" : "Copy Link")
                } siteControls: {
                    URLBoxIconButton(symbol: "slider.horizontal.3", label: "Site controls",
                                     id: URLBoxIconButton.siteControlsID, tint: tint, action: openSiteControls)
                        .onHover { inside in inside ? model.pointerEntered() : model.pointerExited() }
                        // Below the icon with an arrow pointing up at it, 12 pt below the icon,
                        // centered on it. [07 §12] observed. Our own panel, not a popover (B42).
                        .siteControlsBubble(model, isPresented: model.isPresented, palette: chrome)
                        // Extension popups open from the same button (C14). inferred.
                        .extensionPopupBubble(model, tabID: model.extensionPopup?.tabID, palette: chrome)
                }
            }
        }
    }
}

/// Places the URL box icons: right-aligned `urlBoxButtonTrailingInset` in from the box's right
/// edge and vertically centered in it, copy link directly left of site controls. [07 §12] observed
/// for the site controls icon; copy link's place inferred.
struct URLBoxIconRow<CopyLink: View, SiteControls: View>: View {
    @ViewBuilder let copyLink: () -> CopyLink
    @ViewBuilder let siteControls: () -> SiteControls

    var body: some View {
        HStack(spacing: SiteControlsLocalTokens.urlBoxButtonSpacing) {
            Spacer(minLength: 0)
            copyLink()
            siteControls()
        }
        .padding(.trailing, SiteControlsLocalTokens.urlBoxButtonTrailingInset)
        .frame(maxHeight: .infinity)
    }
}

/// Frames of the URL box icons for a URL box at `box` (same coordinates). [07 §12] observed: the
/// box at x 8–268, y 46–82 puts site controls at x 234–264, y 49–79; copy link directly left of
/// it, inferred.
enum URLBoxIconLayout {
    static func siteControlsFrame(inURLBox box: CGRect) -> CGRect {
        let size = SiteControlsLocalTokens.urlBoxButtonSize
        return CGRect(x: box.maxX - SiteControlsLocalTokens.urlBoxButtonTrailingInset - size,
                      y: box.midY - size / 2, width: size, height: size)
    }

    static func copyLinkFrame(inURLBox box: CGRect) -> CGRect {
        let site = siteControlsFrame(inURLBox: box)
        return site.offsetBy(dx: -(site.width + SiteControlsLocalTokens.urlBoxButtonSpacing), dy: 0)
    }
}

/// One icon button at the right end of the URL box: a 30 × 30 box with a centered glyph. Both URL
/// box icons use it, with or without a Site Control Center model, so the bubble always anchors
/// to the measured box. [07 §12] observed size.
struct URLBoxIconButton: View {
    static let copyLinkID = "openarc.sidebar.copyLinkButton"
    static let siteControlsID = "openarc.sidebar.siteControlsButton"

    let symbol: String
    let label: String
    let id: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SiteControlsLocalTokens.urlBoxGlyphSize, weight: .medium))
                .foregroundStyle(tint.opacity(Metrics.IconOpacity.enabled))
                .frame(width: SiteControlsLocalTokens.urlBoxButtonSize, height: SiteControlsLocalTokens.urlBoxButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Geometry of the bubble's content, top to bottom: tool row, "Extensions", "Settings", footer,
/// `padding` on every side. Heights are fixed so the bubble size follows the content without
/// measuring it. [04 §网页工具栏 (E16)] observed: one settings row and no extension give the
/// 236 × 254 bubble in its 262 × 280 window; [07 §12] observed ≈ 296 with two rows.
struct SiteControlsLayout: Equatable {
    var extensionCount: Int
    var settingRowCount: Int

    private typealias T = SiteControlsLocalTokens

    var width: CGFloat { T.width }

    /// The four tool buttons, relative to the bubble: 48 × 32 at a 56 pt pitch.
    var toolFrames: [CGRect] {
        (0..<SiteControlsTool.allCases.count).map { gridFrame(column: $0, top: T.padding) }
    }

    /// Extension buttons plus the trailing "+", 4 per line on the tools' grid. [06 §17.3] observed
    /// "+" 48 × 32; extension buttons share its size, inferred.
    var extensionCellCount: Int { extensionCount + 1 }
    var extensionLines: Int { (extensionCellCount + T.toolColumns - 1) / T.toolColumns }

    var extensionsHeaderTop: CGFloat { T.padding + T.toolButtonSize.height + T.sectionSpacing }
    var extensionsGridTop: CGFloat { extensionsHeaderTop + T.headerHeight + T.headerSpacing }
    var extensionsGridHeight: CGFloat {
        CGFloat(extensionLines) * T.toolButtonSize.height + CGFloat(extensionLines - 1) * T.toolSpacing
    }

    func extensionCellFrame(index: Int) -> CGRect {
        let line = CGFloat(index / T.toolColumns)
        return gridFrame(column: index % T.toolColumns,
                         top: extensionsGridTop + line * (T.toolButtonSize.height + T.toolSpacing))
    }

    var settingsHeaderTop: CGFloat { extensionsGridTop + extensionsGridHeight + T.sectionSpacing }
    var settingsRowsTop: CGFloat { settingsHeaderTop + T.headerHeight + T.headerSpacing }

    var footerFrame: CGRect {
        CGRect(x: T.padding, y: settingsRowsTop + CGFloat(settingRowCount) * T.rowHeight + T.sectionSpacing,
               width: width - 2 * T.padding, height: T.footerHeight)
    }

    /// Height of the bubble.
    var height: CGFloat { footerFrame.maxY + T.padding }

    /// The window around the bubble in the reference: `windowMargin` on every side.
    /// [04 §网页工具栏 (E16)] observed (262 × 280 around 236 × 254).
    var referenceWindowSize: CGSize {
        let margin = CGFloat(Metrics.SiteControls.windowMargin)
        return CGSize(width: width + 2 * margin, height: height + 2 * margin)
    }

    private func gridFrame(column: Int, top: CGFloat) -> CGRect {
        CGRect(x: T.padding + CGFloat(column) * T.toolPitch, y: top,
               width: T.toolButtonSize.width, height: T.toolButtonSize.height)
    }
}

/// The bubble. Top to bottom: 4 tool buttons; "Extensions" ("+", and "Manage" when extensions
/// exist); "Settings" rows; "Secure" pill and "⋯". [06 §12] observed; geometry from
/// `SiteControlsLayout`.
struct SiteControlsView: View {
    @ObservedObject var model: SiteControlsModel

    private typealias T = SiteControlsLocalTokens

    var body: some View {
        let layout = model.contentLayout
        VStack(alignment: .leading, spacing: T.sectionSpacing) {
            tools
            extensionsSection(layout)
            settingsSection
            footer
        }
        .padding(T.padding)
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .onHover { inside in inside ? model.pointerEntered() : model.pointerExited() }
        .onExitCommand { model.close(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.siteControls")
    }

    /// Four 48 × 32 buttons at a 56 pt pitch. [04 §网页工具栏 (E16)] observed.
    private var tools: some View {
        HStack(spacing: T.toolSpacing) {
            ForEach(SiteControlsTool.allCases, id: \.self) { tool in
                Button { model.run(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15))
                        .frame(width: T.toolButtonSize.width, height: T.toolButtonSize.height)
                        .background(RoundedRectangle(cornerRadius: T.toolCornerRadius).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canRun(tool))
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityIdentifier("openarc.siteControls.tool.\(tool.rawValue)")
                .background {
                    if tool == .share { SharePickerAnchor(model: model) }
                }
            }
        }
        .frame(height: T.toolButtonSize.height)
    }

    private func extensionsSection(_ layout: SiteControlsLayout) -> some View {
        VStack(alignment: .leading, spacing: T.headerSpacing) {
            HStack {
                header("Extensions")
                Spacer()
                if model.showsManageExtensions {
                    Button("Manage") { model.manageExtensionsHandler?() }
                        .buttonStyle(.plain)
                        .font(Typography.panelHeader.font)
                        .foregroundStyle(.secondary)
                        .disabled(model.manageExtensionsHandler == nil)
                        .accessibilityIdentifier("openarc.siteControls.manageExtensions")
                }
            }
            .frame(height: T.headerHeight)
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.settings.extensions.enumerated()), id: \.element.id) { index, ext in
                    Button { model.runExtension(ext.id) } label: {
                        ExtensionActionIcon(action: ext)
                            .frame(width: T.toolButtonSize.width, height: T.toolButtonSize.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!ext.isEnabled)
                    .help(ext.title)
                    .accessibilityLabel(ext.name)
                    .accessibilityIdentifier("openarc.siteControls.extension.\(ext.id)")
                    .contextMenu { extensionMenu(ext) }
                    .offset(cellOffset(layout, index: index))
                }
                Button { model.addExtensionHandler?() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .frame(width: T.toolButtonSize.width, height: T.toolButtonSize.height)
                        .background(RoundedRectangle(cornerRadius: T.toolCornerRadius).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.addExtensionHandler == nil)
                .accessibilityLabel("Add Extension")
                .accessibilityIdentifier("openarc.siteControls.addExtension")
                .offset(cellOffset(layout, index: layout.extensionCount))
            }
            .frame(width: T.toolRowWidth, height: layout.extensionsGridHeight, alignment: .topLeading)
        }
    }

    /// An action's right-click menu (B116): the extension's name, its own `contextMenus` items
    /// (B124), then Manage / Remove. inferred.
    @ViewBuilder
    private func extensionMenu(_ ext: SiteExtensionAction) -> some View {
        Text(ext.name)
        Divider()
        let own = model.extensionOwnMenuItems(for: ext.id)
        if !own.isEmpty {
            ForEach(Array(own.enumerated()), id: \.offset) { _, item in
                ExtensionOwnMenuItemView(item: item) { model.performExtensionOwnMenuItem($0, extensionID: ext.id) }
            }
            Divider()
        }
        ForEach(model.extensionMenuItems(for: ext.id), id: \.self) { item in
            Button(item.title(extensionName: ext.name)) { model.perform(item, extensionID: ext.id) }
                .disabled(!model.isEnabled(item, extensionID: ext.id))
        }
    }

    private func cellOffset(_ layout: SiteControlsLayout, index: Int) -> CGSize {
        let frame = layout.extensionCellFrame(index: index)
        return CGSize(width: frame.minX - T.padding, height: frame.minY - layout.extensionsGridTop)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: T.headerSpacing) {
            header("Settings").frame(height: T.headerHeight)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.settingRows) { row in
                    Button { model.activate(row.kind) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 12))
                                .frame(width: T.rowIconSize, height: T.rowIconSize)
                                .background(Circle().fill(Color.primary.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.title).font(Typography.panelRowTitle.font).lineLimit(1)
                                Text(row.status).font(Typography.panelRowDetail.font).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: T.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(row.title)
                    .accessibilityLabel("\(row.title), \(row.status)")
                }
            }
        }
    }

    /// "Insecure" / "Secure" pill and "⋯". [06 §12], [06 §17.3] observed pill; [06 §19.1] observed
    /// menu. The menu has no icons ([06 §19.1] lists titles only). Permission rows stay in the
    /// Settings section.
    private var footer: some View {
        HStack {
            HStack(spacing: 3) {
                Image(systemName: model.site?.isSecure == false ? "lock.slash" : "lock.fill").font(.system(size: 10))
                Text(model.securityLabel).font(Typography.panelRowDetail.font)
            }
            .padding(.horizontal, 10)
            .frame(height: SiteControlsLocalTokens.footerHeight)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("openarc.siteControls.security")
            Spacer()
            Menu {
                ForEach(Array(SiteControlsMenuItem.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { item in
                        Button(item.title) { model.perform(item) }
                            .disabled(!model.isEnabled(item))
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: SiteControlsLocalTokens.footerHeight, height: SiteControlsLocalTokens.footerHeight)
            .accessibilityLabel("More")
            .accessibilityIdentifier("openarc.siteControls.more")
        }
        .frame(height: SiteControlsLocalTokens.footerHeight)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Typography.panelHeader.font)
            .foregroundStyle(.secondary)
    }
}

extension SiteControlsModel {
    /// Geometry of the bubble for the current site: its extensions and settings rows.
    var contentLayout: SiteControlsLayout {
        SiteControlsLayout(extensionCount: settings.extensions.count, settingRowCount: settingRows.count)
    }
}

extension View {
    /// Anchors the Site Control Center bubble to this view (the URL box icon or the toolbar
    /// button): below it, centered, arrow up, 12 pt gap. [07 §12] observed; [06 §17.3] observed
    /// that in the toolbar it points at the site controls button. The height comes from
    /// `SiteControlsLayout`, so the bubble is never measured.
    func siteControlsBubble(_ model: SiteControlsModel, isPresented: Bool, palette: ThemePalette) -> some View {
        floatingBubble(isPresented: isPresented) { siteControlsBubbleRequest(model, palette: palette) }
    }
}

/// The Site Control Center bubble request, shared by the URL box icon and the toolbar button.
@MainActor
func siteControlsBubbleRequest(_ model: SiteControlsModel, palette: ThemePalette) -> FloatingBubbleRequest {
    let layout = model.contentLayout
    return FloatingBubbleRequest(
        placement: .attached(.below),
        style: FloatingBubbleStyle(width: layout.width, height: layout.height,
                                   cornerRadius: SiteControlsLocalTokens.cornerRadius,
                                   tint: palette.floatingPanelBackground, isDark: palette.isDark, usesGradient: true),
        content: AnyView(SiteControlsView(model: model).environment(\.colorScheme, palette.isDark ? .dark : .light)),
        onDismiss: { reason in model.close(reason == .escape ? .escape : .clickOutside) }
    )
}

// MARK: - Share (B80)

/// Sits behind the Share button and shows the system share picker for `shareRequest` below it.
/// The picker reports back once, with or without a chosen service, and the bubble then closes.
private struct SharePickerAnchor: NSViewRepresentable {
    @ObservedObject var model: SiteControlsModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        guard let request = model.shareRequest, coordinator.shownSerial != request.serial else { return }
        coordinator.shownSerial = request.serial
        // After this update pass: the picker runs a modal menu loop.
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                guard let view, view.window != nil, model.shareRequest?.serial == request.serial else {
                    model.finishShare(serial: request.serial)
                    return
                }
                coordinator.pending = request.serial
                let picker = NSSharingServicePicker(items: [request.url])
                picker.delegate = coordinator
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        weak var model: SiteControlsModel?
        var shownSerial: Int?
        var pending: Int?

        /// Called once per picker: with the chosen service, or nil when it was dismissed.
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let serial = pending else { return }
            pending = nil
            model?.finishShare(serial: serial)
        }
    }
}

// MARK: - Extension actions (C14)

/// One extension's button in the "Extensions" section: its action icon for the tab (an SF Symbol
/// until it loads) with the badge the extension set. [06 §12] observed section and "+" button; the
/// look of an extension's button there is not recorded: size and badge inferred (Chrome's toolbar
/// draws a 16 pt icon with a small badge at the lower right).
struct ExtensionActionIcon: View {
    let action: SiteExtensionAction

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = action.iconPNGData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: SiteControlsLocalTokens.extensionIconSize, height: SiteControlsLocalTokens.extensionIconSize)
                } else {
                    Image(systemName: action.symbol).font(.system(size: 13))
                }
            }
            .frame(width: 24, height: 24)
            .opacity(action.isEnabled ? 1 : 0.4)
            if !action.badgeText.isEmpty {
                Text(action.badgeText)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .frame(minWidth: 12, minHeight: 10)
                    .background(Capsule().fill(Color(nsColor: .systemGray)))
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Extension popup (C14)

/// The bubble that shows an extension's popup page. It opens from the site controls button, below
/// it with the arrow up, like the Site Control Center (inferred: the spec does not record extension
/// popups), shows once the page loaded, follows the page's size and takes the keyboard. A click
/// outside or Escape closes it.
struct ExtensionPopupBubbleContent: View {
    @ObservedObject var model: SiteControlsModel

    var body: some View {
        ExtensionPopupHostView(model: model)
            .padding(SiteControlsLocalTokens.extensionPopupInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("openarc.extensionPopup")
    }
}

/// Hosts the popup page's native view (`ExtensionPopup.attach(to:)`).
private struct ExtensionPopupHostView: NSViewRepresentable {
    let model: SiteControlsModel

    func makeNSView(context: Context) -> SurfaceContainerView {
        let view = SurfaceContainerView()
        model.attachExtensionPopup(to: view)
        return view
    }

    func updateNSView(_ nsView: SurfaceContainerView, context: Context) {}

    static func dismantleNSView(_ nsView: SurfaceContainerView, coordinator: ()) {
        nsView.clear()
    }
}

extension View {
    /// Anchors the extension popup bubble to this view (the site controls button). inferred.
    func extensionPopupBubble(_ model: SiteControlsModel, tabID: UUID?, palette: ThemePalette) -> some View {
        let popup = model.extensionPopup
        let isPresented = popup.map { $0.isLoaded && $0.tabID == tabID } ?? false
        return floatingBubble(isPresented: isPresented) {
            let inset = SiteControlsLocalTokens.extensionPopupInset * 2
            return FloatingBubbleRequest(
                placement: .attached(.below),
                style: FloatingBubbleStyle(width: CGFloat(popup?.width ?? 0) + inset,
                                           height: CGFloat(popup?.height ?? 0) + inset,
                                           cornerRadius: SiteControlsLocalTokens.extensionPopupCornerRadius,
                                           tint: palette.floatingPanelBackground, isDark: palette.isDark,
                                           becomesKey: true),
                content: AnyView(ExtensionPopupBubbleContent(model: model)),
                onDismiss: { _ in model.closeExtensionPopup() },
                onBecameKey: { model.focusExtensionPopup() }
            )
        }
    }
}

/// One of an extension's own action menu items (B124), with its submenus.
private struct ExtensionOwnMenuItemView: View {
    let item: PageContextMenuItem
    let perform: (Int) -> Void

    var body: some View {
        if !item.isVisible {
            EmptyView()
        } else {
            switch item.kind {
            case .separator:
                Divider()
            case .submenu:
                Menu(item.title) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        ExtensionOwnMenuItemView(item: child, perform: perform)
                    }
                }
                .disabled(!item.isEnabled)
            case .checkbox:
                Toggle(item.title, isOn: Binding(get: { item.isChecked }, set: { _ in perform(item.id) }))
                    .disabled(!item.isEnabled)
            case .command:
                Button(item.title) { perform(item.id) }
                    .disabled(!item.isEnabled)
            }
        }
    }
}
