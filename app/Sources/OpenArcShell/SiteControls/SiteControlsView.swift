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

/// The two icons at the right end of the URL box: copy link (chain) and site controls (sliders).
/// They show while the box is hovered, and stay while the bubble is open so it keeps its anchor.
/// [06 §12] observed.
struct SiteControlsURLBoxAccessories: View {
    @ObservedObject var model: SiteControlsModel
    let isHovering: Bool
    let tint: Color
    /// Palette of the window: the bubble takes its floating-panel tint. [07 §12] observed.
    let chrome: ThemePalette
    let openSiteControls: () -> Void

    var body: some View {
        if isHovering || model.isPresented || model.isLinkCopied || model.extensionPopup != nil {
            HStack(spacing: 2) {
                Spacer()
                SiteControlsIconButton(
                    symbol: model.isLinkCopied ? "checkmark" : "link",
                    label: model.isLinkCopied ? "Copied" : "Copy link",
                    id: "openarc.sidebar.copyLinkButton",
                    tint: tint
                ) {
                    model.copyLink()
                }
                .help(model.isLinkCopied ? "Copied" : "Copy Link")
                SiteControlsIconButton(symbol: "slider.horizontal.3", label: "Site controls",
                                       id: "openarc.sidebar.siteControlsButton", tint: tint, action: openSiteControls)
                    .onHover { inside in inside ? model.pointerEntered() : model.pointerExited() }
                    // Below the icon with an arrow pointing up at it, 12 pt below the icon,
                    // centered on it. [07 §12] observed. Our own panel, not a popover (B42).
                    .floatingBubble(isPresented: model.isPresented) {
                        FloatingBubbleRequest(
                            placement: .attached(.below),
                            style: FloatingBubbleStyle(width: SiteControlsLocalTokens.width, height: nil,
                                                       cornerRadius: SiteControlsLocalTokens.cornerRadius,
                                                       tint: chrome.floatingPanelBackground, isDark: chrome.isDark),
                            content: AnyView(SiteControlsView(model: model).environment(\.colorScheme, chrome.isDark ? .dark : .light)),
                            onDismiss: { reason in model.close(reason == .escape ? .escape : .clickOutside) }
                        )
                    }
                    // Extension popups open from the same button (C14). inferred.
                    .extensionPopupBubble(model, tabID: model.extensionPopup?.tabID, palette: chrome)
            }
            .padding(.trailing, 6)
        }
    }
}

struct SiteControlsIconButton: View {
    let symbol: String
    let label: String
    let id: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.opacity(Metrics.IconOpacity.enabled))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The bubble. Top to bottom: 4 square tool buttons; "Extensions" ("+", and "Manage" when
/// extensions exist); "Settings" rows; "Secure" pill and "⋯". [06 §12] observed.
struct SiteControlsView: View {
    @ObservedObject var model: SiteControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SiteControlsLocalTokens.sectionSpacing) {
            tools
            extensionsSection
            settingsSection
            footer
        }
        .padding(SiteControlsLocalTokens.padding)
        .frame(width: SiteControlsLocalTokens.width)
        .onHover { inside in inside ? model.pointerEntered() : model.pointerExited() }
        .onExitCommand { model.close(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.siteControls")
    }

    private var tools: some View {
        HStack(spacing: SiteControlsLocalTokens.toolSpacing) {
            ForEach(SiteControlsTool.allCases, id: \.self) { tool in
                Button { model.run(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(RoundedRectangle(cornerRadius: SiteControlsLocalTokens.toolCornerRadius).fill(Color.primary.opacity(0.06)))
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
    }

    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: SiteControlsLocalTokens.toolSpacing) {
                ForEach(model.settings.extensions) { ext in
                    Button { model.runExtension(ext.id) } label: { ExtensionActionIcon(action: ext) }
                        .buttonStyle(.plain)
                        .disabled(!ext.isEnabled)
                        .help(ext.title)
                        .accessibilityLabel(ext.name)
                        .accessibilityIdentifier("openarc.siteControls.extension.\(ext.id)")
                }
                Button { model.addExtensionHandler?() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(model.addExtensionHandler == nil)
                .accessibilityLabel("Add Extension")
                .accessibilityIdentifier("openarc.siteControls.addExtension")
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            header("Settings")
            ForEach(model.settingRows) { row in
                Button { model.activate(row.kind) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 12))
                            .frame(width: SiteControlsLocalTokens.rowIconSize, height: SiteControlsLocalTokens.rowIconSize)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).font(Typography.panelRowTitle.font).lineLimit(1)
                            Text(row.status).font(Typography.panelRowDetail.font).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.title)
                .accessibilityLabel("\(row.title), \(row.status)")
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
            .padding(.horizontal, 6)
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
            .frame(height: SiteControlsLocalTokens.footerHeight)
            .accessibilityLabel("More")
            .accessibilityIdentifier("openarc.siteControls.more")
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Typography.panelHeader.font)
            .foregroundStyle(.secondary)
    }
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
