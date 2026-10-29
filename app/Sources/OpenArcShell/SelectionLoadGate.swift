import Foundation

/// Paces the engine tabs that selections make (B107). Making a Chromium tab and committing its
/// first page cost most of a frame on the main thread, so while selections come faster than that
/// (Next Tab held down, quick clicks down the list) each selection's frame would also carry the
/// previous tabs' engine work. A selection made within `burstGap` of the previous one therefore
/// waits with its engine tab until selections have been quiet for `burstGap`. Then the tabs on
/// screen are made at once and the tabs that were passed over follow, one per run loop pass. A
/// selection after a quiet moment is never held. Own design; the spec records no loading policy
/// for tabs passed over quickly.
@MainActor
final class SelectionLoadGate {
    /// Selections closer together than this form a burst, and a burst ends after this long
    /// without a selection. Own value: longer than key repeat (≈ 30–80 ms) and quick clicks,
    /// short next to the time a person looks at a page before moving on.
    static let burstGap: TimeInterval = 0.1

    /// Whether tab `id` is shown in a window now. Set by the owner.
    var isOnScreen: (UUID) -> Bool = { _ in false }
    /// Number of tabs waiting. For tests.
    var waitingCount: Int { waiters.count }

    private let uptime: () -> TimeInterval
    private var lastSelection: TimeInterval?
    /// Tabs waiting for the burst to end, oldest first.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    /// The passed-over tab let through last, until its engine tab is made (`finished`).
    private var backgroundID: UUID?
    private var quietTask: Task<Void, Never>?
    private var isStopped = false

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    /// Records a selection made now. Returns whether it is part of a burst.
    func noteSelection() -> Bool {
        let now = uptime()
        defer { lastSelection = now }
        guard let lastSelection else { return false }
        return now - lastSelection < Self.burstGap
    }

    /// Returns once tab `id`'s engine tab may be made: at once unless `inBurst`; else when
    /// selections are quiet (`release`). The caller calls `finished(_:)` after making it.
    func admit(_ id: UUID, inBurst: Bool) async {
        guard inBurst, !isStopped else { return }
        await withCheckedContinuation { continuation in
            waiters.append((id, continuation))
            scheduleRelease()
        }
    }

    /// The engine tab of `id` was made (or was not needed): the next passed-over tab goes in a
    /// later pass, so each gets a frame of its own.
    func finished(_ id: UUID) {
        guard backgroundID == id else { return }
        Task { [weak self] in
            await MainRunLoopTurn.next()
            guard let self, self.backgroundID == id else { return }
            self.backgroundID = nil
            self.release()
        }
    }

    /// Lets every waiter through and stops holding new ones (the controller stopped).
    func stop() {
        isStopped = true
        quietTask?.cancel()
        quietTask = nil
        let all = waiters
        waiters.removeAll()
        all.forEach { $0.continuation.resume() }
    }

    /// Runs `release` once selections have been quiet for `burstGap`.
    private func scheduleRelease() {
        guard quietTask == nil else { return }
        quietTask = Task { [weak self] in
            while true {
                guard let wait = self?.remainingBurst(), wait > 0 else { break }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
                if Task.isCancelled { return }
            }
            self?.quietTask = nil
            self?.release()
        }
    }

    /// Seconds until the current burst counts as over (≤ 0: it is).
    private func remainingBurst() -> TimeInterval {
        guard let lastSelection else { return 0 }
        return lastSelection + Self.burstGap - uptime()
    }

    /// Selections are quiet: the tabs on screen go now, then the others one at a time.
    private func release() {
        guard !waiters.isEmpty else { return }
        guard remainingBurst() <= 0 else {
            scheduleRelease()
            return
        }
        let shown = waiters.filter { isOnScreen($0.id) }
        waiters.removeAll { isOnScreen($0.id) }
        shown.forEach { $0.continuation.resume() }
        guard backgroundID == nil, !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        backgroundID = next.id
        next.continuation.resume()
    }
}
