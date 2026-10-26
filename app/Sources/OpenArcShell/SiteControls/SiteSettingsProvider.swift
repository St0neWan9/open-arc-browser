import Foundation
import OpenArcEngine

// Engine-side site settings, as the Site Control Center needs them.
//
// This protocol lives in the Shell on purpose: the real implementation needs the Chromium
// bridge (content settings, permission manager, cookie store, zoom map, extension actions,
// ad blocker), and its final shape is decided there. Plan tasks:
// - C12: permission prompts and stored permission decisions (camera, microphone, location,
//   notifications), cookies / site data.
// - C14: extension toolbar actions shown in the "Extensions" section (`EngineSiteSettingsProvider`
//   reads them from `BrowserEngine.extensions`).
// - C16: the ad-blocking toggle.
// Until then `FakeSiteSettingsProvider` serves fake data so the popover can be built and tested.

// `SiteOrigin`, `SitePermissionKind` and `SitePermissionDecision` live in OpenArcEngine
// (SiteOrigin.swift) since C7b: engine dialog requests name the requesting origin too.

/// An extension's toolbar action for the current tab (C14), as the Site Control Center's
/// "Extensions" section shows it ([06 §12] observed section; [06 §17.2] observed that the toolbar
/// has no extension buttons, so this is where they live).
public struct SiteExtensionAction: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol shown while the extension has no icon (still loading, or a fake). unknown.
    public var symbol: String
    /// The action's icon for the tab, PNG (16 pt at 2x).
    public var iconPNGData: Data?
    /// Badge text the extension set for the tab ("12"); empty when none.
    public var badgeText: String
    /// Tooltip: the action's title for the tab, else the extension's name.
    public var title: String
    /// The action is enabled on this tab.
    public var isEnabled: Bool
    /// Clicking opens the extension's popup (else the click goes to the extension).
    public var hasPopup: Bool

    public init(
        id: String, name: String, symbol: String = "puzzlepiece.extension", iconPNGData: Data? = nil,
        badgeText: String = "", title: String? = nil, isEnabled: Bool = true, hasPopup: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.iconPNGData = iconPNGData
        self.badgeText = badgeText
        self.title = title ?? name
        self.isEnabled = isEnabled
        self.hasPopup = hasPopup
    }

    /// From the engine's action state for a tab.
    public init(_ info: EngineExtensionInfo) {
        self.init(
            id: info.id, name: info.name, iconPNGData: info.iconPNGData, badgeText: info.badgeText,
            title: info.actionTitle.isEmpty ? info.name : info.actionTitle,
            isEnabled: info.isActionEnabled, hasPopup: info.hasPopup
        )
    }
}

/// Everything the popover shows for one site.
public struct SiteSettingsState: Equatable, Sendable {
    public var permissions: [SitePermissionKind: SitePermissionDecision]
    /// "Developer Mode" row; default Off. [06 §12] observed.
    public var isDeveloperModeOn: Bool
    /// "Automatic Picture-In-Picture" row; default Allowed. [06 §12] observed.
    public var isAutomaticPictureInPictureAllowed: Bool
    /// Page zoom in percent (100 = default). inferred.
    public var zoomPercent: Int
    /// Number of cookies stored for the site. inferred.
    public var cookieCount: Int
    /// Ad blocking for this site (C16); nil while the engine has no ad blocker. inferred.
    public var isAdBlockingOn: Bool?
    /// Installed extensions with an action for this site (C14).
    public var extensions: [SiteExtensionAction]

    public init(
        permissions: [SitePermissionKind: SitePermissionDecision] = [:],
        isDeveloperModeOn: Bool = false,
        isAutomaticPictureInPictureAllowed: Bool = true,
        zoomPercent: Int = 100,
        cookieCount: Int = 0,
        isAdBlockingOn: Bool? = nil,
        extensions: [SiteExtensionAction] = []
    ) {
        self.permissions = permissions
        self.isDeveloperModeOn = isDeveloperModeOn
        self.isAutomaticPictureInPictureAllowed = isAutomaticPictureInPictureAllowed
        self.zoomPercent = zoomPercent
        self.cookieCount = cookieCount
        self.isAdBlockingOn = isAdBlockingOn
        self.extensions = extensions
    }

    /// Defaults the popover shows for a site with no stored settings. [06 §12] observed:
    /// Developer Mode Off, Automatic Picture-In-Picture Allowed.
    public static let defaults = SiteSettingsState()

    public func decision(for kind: SitePermissionKind) -> SitePermissionDecision {
        permissions[kind] ?? .ask
    }
}

/// One change the popover asks the engine to make.
public enum SiteSettingChange: Equatable, Sendable {
    case permission(SitePermissionKind, SitePermissionDecision)
    case developerMode(Bool)
    case automaticPictureInPicture(Bool)
    case zoom(percent: Int)
    case adBlocking(Bool)
    case clearSiteData
}

/// Site settings as provided by the engine. Settings are kept per Profile (each Profile is its
/// own browsing context). See the file header for the plan tasks that implement this for real.
@MainActor
public protocol SiteSettingsProvider: AnyObject {
    func settings(for site: SiteOrigin, profileID: UUID?) async -> SiteSettingsState
    func apply(_ change: SiteSettingChange, for site: SiteOrigin, profileID: UUID?) async
    /// The extensions with an action on the given tab (C14), or nil when this provider has no
    /// per-tab extension state (then `SiteSettingsState.extensions` is used as is).
    func extensionActions(tabID: UUID, profileID: UUID?) async -> [SiteExtensionAction]?
    /// Runs an extension's toolbar action on the given tab (C14). Returns the popup it opened, not
    /// shown yet, or nil when the action has none.
    func runExtensionAction(_ id: String, tabID: UUID, site: SiteOrigin, profileID: UUID?) async -> (any ExtensionPopup)?
}

/// In-memory stand-in until the Chromium bridge exists (C12 / C14 / C16). Records every call.
@MainActor
public final class FakeSiteSettingsProvider: SiteSettingsProvider {
    struct Key: Hashable {
        var site: SiteOrigin
        var profileID: UUID?
    }

    private var stored: [Key: SiteSettingsState] = [:]
    /// State for sites without stored settings.
    public var baseline: SiteSettingsState
    public private(set) var appliedChanges: [SiteSettingChange] = []
    public private(set) var extensionActionsRun: [String] = []

    public init(baseline: SiteSettingsState = .defaults) {
        self.baseline = baseline
    }

    /// Seeds the state for one site (tests and previews).
    public func set(_ state: SiteSettingsState, for site: SiteOrigin, profileID: UUID?) {
        stored[Key(site: site, profileID: profileID)] = state
    }

    public func settings(for site: SiteOrigin, profileID: UUID?) async -> SiteSettingsState {
        stored[Key(site: site, profileID: profileID)] ?? baseline
    }

    public func apply(_ change: SiteSettingChange, for site: SiteOrigin, profileID: UUID?) async {
        appliedChanges.append(change)
        let key = Key(site: site, profileID: profileID)
        var state = stored[key] ?? baseline
        switch change {
        case .permission(let kind, let decision): state.permissions[kind] = decision
        case .developerMode(let on): state.isDeveloperModeOn = on
        case .automaticPictureInPicture(let allowed): state.isAutomaticPictureInPictureAllowed = allowed
        case .zoom(let percent): state.zoomPercent = percent
        case .adBlocking(let on): state.isAdBlockingOn = on
        case .clearSiteData: state.cookieCount = 0
        }
        stored[key] = state
    }

    public func extensionActions(tabID: UUID, profileID: UUID?) async -> [SiteExtensionAction]? { nil }

    public func runExtensionAction(_ id: String, tabID: UUID, site: SiteOrigin, profileID: UUID?) async -> (any ExtensionPopup)? {
        extensionActionsRun.append(id)
        return nil
    }
}
