import Foundation

// View hosting, isolated in two small protocols so OpenArcEngine never imports a UI framework.
//
// - The engine implements `TabSurface` (one per tab).
// - The shell implements `SurfaceHost` (a container view in the web panel or in one split pane).
// - `attach(to:)` makes the surface hand its content to the host; the host decides layout.
//
// Split view simply means several hosts are on screen, each attached to a different surface.

/// What a host should display for a surface.
public enum SurfaceContent {
    /// The engine's native view. On macOS this is an `NSView`, passed as `AnyObject` so this
    /// module stays UI-free; the shell casts it.
    case native(AnyObject)
    /// No native view (FakeEngine, or a tab that is not loaded yet): the shell draws a
    /// placeholder from this description.
    case placeholder(SurfacePlaceholder)
}

/// Description of placeholder content.
public struct SurfacePlaceholder: Hashable, Sendable {
    public var title: String
    public var url: URL?
    /// The page's color scheme (`BrowserTab.setPreferredColorScheme`), so a placeholder page can
    /// look like a page that honors `prefers-color-scheme`.
    public var colorScheme: WebColorScheme

    public init(title: String, url: URL?, colorScheme: WebColorScheme = .light) {
        self.title = title
        self.url = url
        self.colorScheme = colorScheme
    }
}

/// Implemented by the shell: a place on screen where a tab's content can live.
@MainActor
public protocol SurfaceHost: AnyObject {
    /// Shows `content`, replacing anything shown before.
    func show(_ content: SurfaceContent)
    /// Removes the content (the surface was detached or moved to another host).
    func clear()
}

/// Implemented by the engine: the displayable side of one tab.
public protocol TabSurface: AnyObject, Sendable {
    var tabID: EngineTabID { get }
    /// Attaches to a host, detaching from any previous host first. A surface is in at most one
    /// host at a time.
    @MainActor func attach(to host: any SurfaceHost)
    /// Detaches from the current host, if any.
    @MainActor func detach()
    /// Keyboard focus (the focused split pane gets the brighter toolbar, 06 §5).
    @MainActor func setFocused(_ focused: Bool)
}
