import AppKit
import Carbon.HIToolbox

// "Press ⌥⌘N in any app to open Little Arc" (plan B82).
//
// Spec: [03 §Links] observed: a Little Arc switch "open it with ⌥⌘N in any app"; [02 §窗口与应用]
// observed: ⌥⌘N is New Little Arc Window. The catalog's default (on) predates this task; the spec
// records no default (inferred).
//
// Decisions without evidence (inferred):
//   - The hot key exists while the app runs (no login item, no helper). It is a Carbon hot key
//     (`RegisterEventHotKey`): it needs no Accessibility permission, and the system delivers it
//     whichever app is frontmost.
//   - Inside our own app the hot key wins over the menu item, so ⌥⌘N does the same in both cases:
//     one new Little Arc window. With the switch off, File ▸ New Little Arc Window keeps ⌥⌘N while
//     the app is frontmost.
//   - Pressed in another app, the app activates first so the new window takes the keyboard (B29).

/// Registers one system-wide hot key. Injected through `AppDependencies`, so tests and previews
/// never take a key combination away from the user's other apps.
@MainActor
public protocol GlobalHotKeyService: AnyObject, Sendable {
    /// Registers ⌥⌘N and calls `onPress` on every press. Replaces an earlier registration.
    /// Returns false when the system refused (another app owns the combination).
    @discardableResult
    func registerLittleArcHotKey(onPress: @escaping @MainActor () -> Void) -> Bool
    /// Removes the registration, if any.
    func unregisterLittleArcHotKey()
}

/// Records registrations and lets tests press the key. The default in `AppDependencies`.
@MainActor
public final class RecordingGlobalHotKeyService: GlobalHotKeyService {
    public private(set) var isRegistered = false
    public private(set) var registrationCount = 0
    private var onPress: (@MainActor () -> Void)?

    public nonisolated init() {}

    public func registerLittleArcHotKey(onPress: @escaping @MainActor () -> Void) -> Bool {
        self.onPress = onPress
        isRegistered = true
        registrationCount += 1
        return true
    }

    public func unregisterLittleArcHotKey() {
        onPress = nil
        isRegistered = false
    }

    /// Simulates the user pressing ⌥⌘N in any app. Returns whether a registration handled it.
    @discardableResult
    public func press() -> Bool {
        guard isRegistered, let onPress else { return false }
        onPress()
        return true
    }
}

/// The real hot key: a Carbon `RegisterEventHotKey` registration on the application event target.
@MainActor
public final class CarbonGlobalHotKeyService: GlobalHotKeyService {
    /// "OArc": our hot key signature.
    private static let signature: OSType = 0x4F41_7263
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?

    public nonisolated init() {}

    public func registerLittleArcHotKey(onPress: @escaping @MainActor () -> Void) -> Bool {
        unregisterLittleArcHotKey()
        self.onPress = onPress
        guard installHandler() else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            self.onPress = nil
            return false
        }
        hotKeyRef = ref
        return true
    }

    public func unregisterLittleArcHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        onPress = nil
    }

    /// Installs the hot key event handler once.
    private func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The service lives as long as the app's dependencies (the whole run), so the unretained
        // pointer stays valid for every callback.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard read == noErr, id.signature == CarbonGlobalHotKeyService.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches application-target events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<CarbonGlobalHotKeyService>.fromOpaque(context).takeUnretainedValue().fire()
            }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        return status == noErr
    }

    private func fire() {
        // From another app: come forward so the new window gets the keyboard (B29). inferred.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        onPress?()
    }
}

// MARK: - Preference

extension AppPreferences {
    static let littleArcHotKeyKey = "\(keyPrefix)links.littleArcHotKey"

    /// "Press ⌥⌘N in any app to open Little Arc". [03 §Links] observed switch; on by default
    /// (inferred). Per device.
    public var opensLittleArcWithGlobalHotKey: Bool {
        get { boolValue(Self.littleArcHotKeyKey) ?? true }
        set { setBool(newValue, Self.littleArcHotKeyKey) }
    }
}

extension AppPreferences {
    static let littleArcModifierClickKey = "\(keyPrefix)links.littleArcModifierClick"

    /// "Open Little Arc when you ⌥⌘-click a link". [03 §Links] observed switch; on by default
    /// (inferred). Per device. Read on every ⌥⌘-click (`WorkspaceController.handleNewTabRequest`).
    public var opensLittleArcOnOptionCommandClick: Bool {
        get { boolValue(Self.littleArcModifierClickKey) ?? true }
        set { setBool(newValue, Self.littleArcModifierClickKey) }
    }
}

extension SettingsModel {
    /// Settings ▸ Links ▸ ⌥⌘-click a link opens Little Arc (B82).
    public var opensLittleArcOnOptionCommandClick: Bool {
        get { preferences.opensLittleArcOnOptionCommandClick }
        set {
            objectWillChange.send()
            preferences.opensLittleArcOnOptionCommandClick = newValue
        }
    }

    /// Settings ▸ Links ▸ ⌥⌘N in any app (B82). Changing it registers or removes the hot key.
    public var opensLittleArcWithGlobalHotKey: Bool {
        get { preferences.opensLittleArcWithGlobalHotKey }
        set {
            objectWillChange.send()
            preferences.opensLittleArcWithGlobalHotKey = newValue
            shell.controller.syncLittleArcHotKey()
        }
    }
}

// MARK: - Controller

extension WorkspaceController {
    /// Registers ⌥⌘N with the system when the switch is on, removes it when off. Only the app's
    /// controller owns the hot key (Settings acts on it, `appHost()`); incognito controllers never do.
    func syncLittleArcHotKey() {
        guard !isOffTheRecord else { return }
        let service = dependencies.globalHotKeys
        guard !isStopped, dependencies.preferences.opensLittleArcWithGlobalHotKey else {
            service.unregisterLittleArcHotKey()
            return
        }
        service.registerLittleArcHotKey { [weak self] in self?.openLittleArcFromHotKey() }
    }

    /// ⌥⌘N pressed anywhere: a new, compact Little Arc window (like File ▸ New Little Arc Window).
    func openLittleArcFromHotKey() {
        guard let open = openLittleArcWindow else { return }
        // Keys typed right after ⌥⌘N wait for the new window's field (B29).
        NewWindowTypeAhead.shared.begin(.littleArc)
        open(issueLittleArcWindowID())
    }
}
