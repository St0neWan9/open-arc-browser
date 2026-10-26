import Foundation

// Site-level value types shared by the engine protocols (dialog requests, tab state) and the
// shell's Site Control Center. Moved here from OpenArcShell (chromium-bridge/
// SWIFT_PROTOCOL_CHANGES.md §5) so engine requests can name the requesting origin.
// Bridge counterparts: `OACOrigin`, `OACPermissionKind`, `OACSecurityLevel` (OACDefines.h,
// OACDialogDelegate.h).

/// The site a setting or request applies to: scheme, host and port of the page URL.
public struct SiteOrigin: Hashable, Sendable {
    public var scheme: String
    public var host: String
    /// nil: the scheme's default port.
    public var port: Int?

    public init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    /// nil for URLs without a host (about:blank, file URLs...).
    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    /// The connection is secure (https). Drives the "Secure" pill ([06 §12] observed label) when
    /// the engine reports no `SecurityLevel` of its own.
    public var isSecure: Bool { scheme == "https" }

    /// "host" or "host:port", for dialog texts.
    public var displayHost: String { port.map { "\(host):\($0)" } ?? host }
}

/// Permissions the engine can prompt for and store per site. The first four are the ones the Site
/// Control Center offered before C7b; the rest are Chromium's other prompting permissions
/// (`OACPermissionKind`). The spec lists none of them ([06 §12] shows no permission rows on a
/// fresh site): inferred.
public enum SitePermissionKind: String, CaseIterable, Hashable, Sendable {
    case camera, microphone, location, notifications
    case clipboardRead, midi, storageAccess, screenWakeLock, multipleDownloads, localFonts
    case windowManagement, idleDetection, protectedMedia
}

/// A stored permission decision. `.ask` is the default (the site has no decision).
public enum SitePermissionDecision: String, Hashable, Sendable {
    case ask, allow, block
}

/// Security of the main frame's visible entry (`OACSecurityLevel`). Drives the "Secure" pill
/// ([06 §12] observed label).
public enum SecurityLevel: String, Hashable, Sendable {
    /// http, file, about: and other pages without a secure connection.
    case none
    /// A valid HTTPS connection.
    case secure
    /// HTTPS with mixed or otherwise degraded content.
    case warning
    /// A certificate error the user clicked through, or a site flagged as dangerous.
    case dangerous
}
