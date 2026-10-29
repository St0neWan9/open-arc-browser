import Foundation
import CoreFoundation

/// Waits until the main run loop has drawn its current pass, and resumes in a later pass. B103:
/// work that does not change what a click shows (making the engine tab of a newly selected tab,
/// attaching its surface, mirroring a page's title into its record, refreshing the menu bar) moves
/// out of the click's pass this way, so the click is drawn in one frame and each later step in a
/// pass of its own. Own design; not in the spec.
@MainActor
enum MainRunLoopTurn {
    /// Core Animation commits a pass's drawing in a before-waiting observer of order 2 000 000;
    /// this observer comes after it.
    static let observerOrder: CFIndex = 2_001_000
    /// Resumes anyway after this long, for a main thread that services the main queue without
    /// running the run loop (some test runners). Own value.
    static let fallbackDelay: TimeInterval = 0.05

    /// Returns in a later pass of the main run loop, after the current pass has drawn.
    static func next() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(continuation)
            // One-shot (`repeats` false): the run loop removes it once it fired.
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, false, observerOrder
            ) { _, _ in
                // The pass has drawn; the caller goes on in the next pass, which this block wakes.
                DispatchQueue.main.async { MainActor.assumeIsolated { waiter.resume() } }
            }
            waiter.observer = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) {
                MainActor.assumeIsolated { waiter.resume() }
            }
        }
    }

    /// Resumes its continuation once, whichever of the observer and the fallback comes first.
    @MainActor
    private final class Waiter {
        private var continuation: CheckedContinuation<Void, Never>?
        var observer: CFRunLoopObserver?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            guard let continuation else { return }
            self.continuation = nil
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
            continuation.resume()
        }
    }
}
