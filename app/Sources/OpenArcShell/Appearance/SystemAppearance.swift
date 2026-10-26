import AppKit
import Combine
import OpenArcDesign
import OpenArcEngine

// System light/dark setting and View ▸ Appearance (plan B21).
// [04 §dark mode (E7)] observed: "dark" is a per-Space theme setting (automatic / light / dark
// segments in the theme bubble); automatic follows the system appearance. View ▸ Appearance
// (Automatic / Light / Dark, explanatory line "Websites, Easels, and Notes will use:") only
// decides the color scheme of web content.

/// Where the shell reads the system's light/dark setting. The app passes
/// `ApplicationSystemAppearance`; tests and previews pass `ManualSystemAppearance`, so they never
/// depend on the machine's setting.
public protocol SystemAppearanceSource: AnyObject, Sendable {
    /// The current system appearance.
    @MainActor var current: ResolvedAppearance { get }
    /// Calls `onChange` with later changes (possibly repeating the current value). The returned
    /// token keeps the observation alive.
    @MainActor func observe(_ onChange: @escaping @MainActor (ResolvedAppearance) -> Void) -> AnyCancellable
}

/// A system appearance set by hand (tests, previews, `AppDependencies.fake()`).
@MainActor
public final class ManualSystemAppearance: SystemAppearanceSource {
    private let initial: ResolvedAppearance
    private lazy var subject = CurrentValueSubject<ResolvedAppearance, Never>(initial)

    public nonisolated init(_ initial: ResolvedAppearance = .light) {
        self.initial = initial
    }

    public var current: ResolvedAppearance { subject.value }

    /// Changes the simulated system setting; observers hear about it at once.
    public func set(_ appearance: ResolvedAppearance) {
        guard subject.value != appearance else { return }
        subject.value = appearance
    }

    public func observe(_ onChange: @escaping @MainActor (ResolvedAppearance) -> Void) -> AnyCancellable {
        subject.dropFirst().sink { value in MainActor.assumeIsolated { onChange(value) } }
    }
}

/// The running app's appearance (`NSApplication.effectiveAppearance`), observed with KVO.
@MainActor
public final class ApplicationSystemAppearance: SystemAppearanceSource {
    public nonisolated init() {}

    public var current: ResolvedAppearance {
        Self.resolve(NSApplication.shared.effectiveAppearance)
    }

    public func observe(_ onChange: @escaping @MainActor (ResolvedAppearance) -> Void) -> AnyCancellable {
        // KVO may report the same appearance again; observers ignore repeats.
        let observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in onChange(Self.resolve(NSApplication.shared.effectiveAppearance)) }
        }
        return AnyCancellable { observation.invalidate() }
    }

    static func resolve(_ appearance: NSAppearance) -> ResolvedAppearance {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// View ▸ Appearance choices. [01 §View] observed items Automatic / Light / Dark under the line
/// "Websites, Easels, and Notes will use:". Raw values are persisted; never rename them.
public enum WebAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark

    public static let `default`: WebAppearance = .automatic
    /// The disabled explanatory line above the choices. [01 §View] observed.
    public static let menuExplanation = "Websites, Easels, and Notes will use:"
    /// The submenu title. [01 §View] observed.
    public static let menuTitle = "Appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The scheme a page gets. Light / Dark force it. Automatic follows the page's Space: its theme
    /// appearance, where automatic follows the system. inferred: [04 §dark mode] observed that a
    /// dark Space's pages get `prefers-color-scheme: dark` and that this menu governs web content;
    /// how the two combine was not captured.
    public func colorScheme(spaceAppearance: ResolvedAppearance) -> WebColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return spaceAppearance == .dark ? .dark : .light
        }
    }
}

extension AppPreferences {
    static let webAppearanceKey = "\(keyPrefix)view.webAppearance"

    /// View ▸ Appearance. Per device (app-level, inferred); Automatic by default (inferred).
    public var webAppearance: WebAppearance {
        get { stringValue(Self.webAppearanceKey).flatMap(WebAppearance.init(rawValue:)) ?? .default }
        set { setString(newValue.rawValue, Self.webAppearanceKey) }
    }
}
