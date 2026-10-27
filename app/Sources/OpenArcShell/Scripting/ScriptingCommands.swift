import Foundation
import AppKit
import OpenArcModel

// `make` (plan B70, [06 §29.3] observed: `new` (class, required) and `with properties` (record,
// optional), no `at`). Where the new object goes comes from the object the script told: a window
// or a Space gets a tab, the application gets a window or a Little Arc tab. AppleScript puts that
// target in the event's subject attribute because `make` has no direct parameter. An `at`
// location, if a script sends one anyway, names the container too.

@objc(OAScriptMakeCommand)
final class ScriptMakeCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        let command = ScriptingResultBox(value: self)
        return onScriptingThread { command.value.make() }
    }

    @MainActor
    private func make() -> Any? {
        let host = ScriptingHost.shared
        let kind = createClassDescription.appleEventCode
        let properties = resolvedKeyDictionary
        switch (kind, resolveContainer()) {
        case (ScriptingCodes.tab, let window as ScriptableWindow):
            return runScripting(self) {
                let id = try host.makeTab(inWindow: window.windowID, tabProperties(properties))
                return ScriptableTab(tabID: id, container: .window(window.windowID), host: host).objectSpecifier
            } ?? nil
        case (ScriptingCodes.tab, let space as ScriptableSpace):
            return runScripting(self) {
                let id = try host.makeTab(inSpace: space.spaceID, window: space.windowID, tabProperties(properties))
                return ScriptableTab(tabID: id, container: .space(space.spaceID, window: space.windowID), host: host).objectSpecifier
            } ?? nil
        case (ScriptingCodes.tab, is NSApplication):
            // Little Arc has no scripting object, so the result is empty. inferred.
            _ = runScripting(self) { try host.makeLittleArcTab(tabProperties(properties)) }
            return nil
        case (ScriptingCodes.window, is NSApplication):
            return makeWindow(host, properties)
        default:
            reportScriptingFailure(.failed("Open Arc cannot make that here. Tell a window or a Space to make a tab, or the application to make a window or a tab."), on: self)
            return nil
        }
    }

    @MainActor
    private func tabProperties(_ properties: [String: Any]) -> ScriptTabProperties {
        ScriptTabProperties(
            url: properties[ScriptingKeys.url] as? String,
            location: properties[ScriptingKeys.location] as? String
        )
    }

    /// Opens the window and replies once it is there (the reply waits, `suspendExecution`).
    @MainActor
    private func makeWindow(_ host: ScriptingHost, _ properties: [String: Any]) -> Any? {
        suspendExecution()
        host.makeWindow(
            mode: properties[ScriptingKeys.mode] as? String,
            incognito: (properties[ScriptingKeys.incognito] as? NSNumber)?.boolValue
        ) { [self] result in
            switch result {
            case .success(let id):
                resumeExecution(withResult: id.flatMap { ScriptableWindow(windowID: $0, host: host).objectSpecifier })
            case .failure(let failure):
                reportScriptingFailure(failure, on: self)
                resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    /// The object the new one goes into: the `at` location's container, else the event's subject
    /// (the `tell` target), else the application.
    @MainActor
    private func resolveContainer() -> Any? {
        if let location = arguments?["Location"] as? NSPositionalSpecifier {
            location.evaluate()
            if let container = location.insertionContainer { return container }
        }
        if let subject = appleEvent?.attributeDescriptor(forKeyword: AEKeyword(fourCharacters: "subj")),
           subject.descriptorType == DescType(typeObjectSpecifier),
           let specifier = NSScriptObjectSpecifier(descriptor: subject),
           let object = specifier.objectsByEvaluatingSpecifier {
            return object
        }
        return NSApplication.shared
    }
}

/// Four-letter class codes of the dictionary ([06 §29.2] observed).
enum ScriptingCodes {
    static let tab = FourCharCode(fourCharacters: "tAbB")
    static let window = FourCharCode(fourCharacters: "WiND")
    static let space = FourCharCode(fourCharacters: "sPaC")
}

extension FourCharCode {
    /// The code of a four-character ASCII string.
    init(fourCharacters text: String) {
        self = text.utf8.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
