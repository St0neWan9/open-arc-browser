import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Window-centered modal cards (B91). [07 §12] observed: New Folder, Rename Space and the Delete
// Space confirmation sit centered in the browser window (1281 × 801 → (416, 289); 1000 × 650 →
// (275, 214)) over a gray veil that dims the whole window. They are not system sheets hanging
// under the title bar.
//
// A view declares a card with `.windowModal(id:isPresented:size:card:)` next to the state that
// drives it (sidebar, Library, window flows). The declaration travels up as a preference to the
// `.windowModalHost()` at the window root, which draws the veil and the card above everything
// else, keeps the keyboard on the card and hides the window behind it from VoiceOver.

/// One card declared by a view of the window.
struct WindowModalItem {
    /// Stable per kind of card ("newFolder", "deleteSpace", …). Two declarations with the same id
    /// (the sidebar is also drawn by the hidden-sidebar peek) show one card.
    let id: String
    let size: Size2D
    let content: AnyView
}

/// The cards declared in the window, in declaration order, one per id.
struct WindowModalPreferenceKey: PreferenceKey {
    static var defaultValue: [WindowModalItem] { [] }

    static func reduce(value: inout [WindowModalItem], nextValue: () -> [WindowModalItem]) {
        for item in nextValue() where !value.contains(where: { $0.id == item.id }) {
            value.append(item)
        }
    }
}

/// What is declared, without the views: lets the host (and tests) follow presentation.
struct WindowModalSummary: Equatable {
    let id: String
    let size: Size2D
}

struct WindowModalSummaryKey: PreferenceKey {
    static var defaultValue: [WindowModalSummary] { [] }

    static func reduce(value: inout [WindowModalSummary], nextValue: () -> [WindowModalSummary]) {
        for item in nextValue() where !value.contains(where: { $0.id == item.id }) {
            value.append(item)
        }
    }
}

private struct WindowModalIsPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A window modal card is up in this window. Surfaces that watch the mouse or keys on their
    /// own (sidebar presses, Peek's Esc) stand down while it is.
    var isWindowModalPresented: Bool {
        get { self[WindowModalIsPresentedKey.self] }
        set { self[WindowModalIsPresentedKey.self] = newValue }
    }
}

extension View {
    /// Shows `card` centered in the window over the dimmed window while `isPresented` is true.
    /// The card handles its own Esc and Return (`.keyboardShortcut(.cancelAction)` /
    /// `.keyboardShortcut(.defaultAction)`).
    func windowModal<Card: View>(id: String, isPresented: Bool, size: Size2D, @ViewBuilder card: () -> Card) -> some View {
        let item = isPresented ? WindowModalItem(id: id, size: size, content: AnyView(card())) : nil
        return self
            .transformPreference(WindowModalPreferenceKey.self) { value in
                if let item, !value.contains(where: { $0.id == item.id }) { value.append(item) }
            }
            .transformPreference(WindowModalSummaryKey.self) { value in
                if let item, !value.contains(where: { $0.id == item.id }) {
                    value.append(WindowModalSummary(id: item.id, size: item.size))
                }
            }
    }

    /// Draws the window's modal cards. Apply once, at the root of the window content.
    func windowModalHost() -> some View {
        modifier(WindowModalHost())
    }
}

/// Where a card sits. Pure, for tests.
enum WindowModalLayout {
    /// Top-left of a card centered in the window (top-left origin). A half-point centre rounds to
    /// whole points away from the window's left and bottom edges (AppKit places windows in a
    /// bottom-left space): [07 §12] observed 1281 × 801 → (416, 289) for the 450 × 222 card and
    /// (416, 264) for 450 × 273; 1000 × 650 → (275, 214).
    static func cardOrigin(windowSize: CGSize, cardSize: CGSize) -> CGPoint {
        let x = ((windowSize.width - cardSize.width) / 2).rounded()
        let bottom = ((windowSize.height - cardSize.height) / 2).rounded()
        return CGPoint(x: max(0, x), y: max(0, windowSize.height - cardSize.height - bottom))
    }

    static func cardFrame(windowSize: CGSize, cardSize: CGSize) -> CGRect {
        CGRect(origin: cardOrigin(windowSize: windowSize, cardSize: cardSize), size: cardSize)
    }
}

/// Shows the first declared card over the window.
struct WindowModalHost: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .environment(\.isWindowModalPresented, isPresented)
            // The window behind the card is out of reach, for VoiceOver too.
            .accessibilityHidden(isPresented)
            .onPreferenceChange(WindowModalSummaryKey.self) { isPresented = !$0.isEmpty }
            .overlayPreferenceValue(WindowModalPreferenceKey.self) { items in
                WindowModalLayer(item: items.first)
            }
    }
}

/// The veil and the card.
struct WindowModalLayer: View {
    let item: WindowModalItem?

    var body: some View {
        if let item {
            GeometryReader { proxy in
                let size = CGSize(width: item.size.width, height: item.size.height)
                let frame = WindowModalLayout.cardFrame(windowSize: proxy.size, cardSize: size)
                ZStack(alignment: .topLeading) {
                    // The gray veil over the whole window; presses on it go nowhere. [07 §12] observed.
                    Rectangle()
                        .fill(ThemeDerivation.windowModalDim.swiftUI)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .accessibilityHidden(true)
                    item.content
                        .frame(width: size.width, height: size.height)
                        // Sized to the card: keeps the keyboard on it and marks where it is.
                        .background(WindowModalKeyboard(cardID: item.id))
                        .offset(x: frame.minX, y: frame.minY)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityIdentifier("openarc.windowModal.\(item.id)")
                        // A new card starts fresh (its text field state).
                        .id(item.id)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
    }
}

/// Keeps the keyboard on the card. A web page that has the keyboard would take Return and Esc
/// for itself, so while a card is up the page gives the keyboard up (a text field in the card
/// takes it), Return and Esc go to the card's buttons, and the page gets the keyboard back when
/// the card goes.
struct WindowModalKeyboard: NSViewRepresentable {
    /// The card's id; the view carries it as its `identifier` ("openarc.windowModal.<id>").
    let cardID: String

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.identifier = NSUserInterfaceItemIdentifier("openarc.windowModal.\(cardID)")
        return view
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {}

    final class KeyboardView: NSView {
        private weak var previousResponder: NSResponder?
        private var monitor: WindowModalKeyMonitor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if let responder = window.firstResponder, !(responder is NSText), responder !== window,
               responder !== window.contentView {
                previousResponder = responder
                if let host = window.contentView, !window.makeFirstResponder(host) {
                    window.makeFirstResponder(nil)
                }
            }
            monitor = WindowModalKeyMonitor { [weak self] event in self?.routeToCard(event) ?? false }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window {
                monitor = nil
                if let view = previousResponder as? NSView, view.window === window {
                    window.makeFirstResponder(view)
                }
                previousResponder = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Sends Return / Esc to the card's buttons. Returns whether the event was used.
        private func routeToCard(_ event: NSEvent) -> Bool {
            guard let window, event.windowNumber == window.windowNumber, let host = window.contentView,
                  WindowModalKeys.routesToCard(keyCode: event.keyCode, flags: event.modifierFlags,
                                               responder: WindowModalKeys.Responder(window.firstResponder))
            else { return false }
            return host.performKeyEquivalent(with: event)
        }
    }
}

/// A local key-down monitor, removed when released.
final class WindowModalKeyMonitor {
    private let monitor: Any?

    @MainActor
    init(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let used = MainActor.assumeIsolated { handler(event) }
            return used ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// The keys a card answers. Pure, for tests.
enum WindowModalKeys {
    static let returnKeyCode: UInt16 = 36
    static let enterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53

    /// What has the keyboard, as far as the routing cares.
    enum Responder: Equatable {
        /// A text field of the card (its field editor). `composing`: an input method is mid-word.
        case textField(composing: Bool)
        /// Anything else: the window, its content, a web page.
        case other

        @MainActor
        init(_ responder: NSResponder?) {
            if let text = responder as? NSTextView, text.isFieldEditor {
                self = .textField(composing: text.hasMarkedText())
            } else {
                self = .other
            }
        }
    }

    /// Plain Esc goes to the card's cancel button; plain Return / Enter to its default button,
    /// except in a text field, whose own submit action runs (the same action). Nothing goes to the
    /// card while an input method is composing.
    static func routesToCard(keyCode: UInt16, flags: NSEvent.ModifierFlags, responder: Responder) -> Bool {
        let modifiers = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        switch (keyCode, responder) {
        case (_, .textField(composing: true)):
            return false
        case (escapeKeyCode, _):
            return true
        case (returnKeyCode, .other), (enterKeyCode, .other):
            return true
        default:
            return false
        }
    }
}
