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
        if isHovering || model.isPresented || model.isLinkCopied {
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
                .disabled(!model.canRunTools)
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityIdentifier("openarc.siteControls.tool.\(tool.rawValue)")
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
                    Button { model.runExtension(ext.id) } label: {
                        Image(systemName: ext.symbol).font(.system(size: 13)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(ext.name)
                    .accessibilityLabel(ext.name)
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

    private var footer: some View {
        HStack {
            HStack(spacing: 3) {
                Image(systemName: model.site?.isSecure == false ? "lock.open" : "lock.fill").font(.system(size: 10))
                Text(model.securityLabel).font(Typography.panelRowDetail.font)
            }
            .padding(.horizontal, 6)
            .frame(height: SiteControlsLocalTokens.footerHeight)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .accessibilityIdentifier("openarc.siteControls.security")
            Spacer()
            Menu {
                Button("Clear Site Data") { model.clearSiteData() }
                ForEach(model.menuPermissionKinds, id: \.self) { kind in
                    Menu(kind.title) {
                        Button("Ask") { model.setPermission(kind, .ask) }
                        Button("Allow") { model.setPermission(kind, .allow) }
                        Button("Block") { model.setPermission(kind, .block) }
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
