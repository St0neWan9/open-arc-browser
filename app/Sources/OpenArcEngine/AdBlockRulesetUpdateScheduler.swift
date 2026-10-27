import Foundation

// When filter-list update checks run (plan C19, gated on the ad-blocking switch by plan B88).
//
// docs/release.md §Network use lists the update check as a connection the app makes; B88 limits
// it to when it serves a purpose: no request goes out while the user has ad blocking switched off.
// The rules (our design; the spec records only the switch, [00 §A 内核继承] "广告拦截" observed):
//
// - A check needs the switch on. The switch is read right before each check, so a change made
//   anywhere (Settings, the Site Control Center row, the engine's own preference) is honoured.
// - Turning the switch off cancels the pending check; a check already running finishes (its
//   result is still stored and applied) and no further one follows.
// - Turning it on schedules a check: `initialDelay` from now, or later when the last check of this
//   run is less than `checkInterval` ago (the interval is kept, toggling never forces extra checks).
// - With the switch found off, the scheduler goes idle until it is turned on again.
// - A check that reports "stop" (engine gone, framework without live updates) ends it for good.

/// Runs ad-block filter-list update checks while ad blocking is on. Main actor: it is driven by
/// the settings switch and by the engine, both on the main actor.
@MainActor
public final class AdBlockRulesetUpdateScheduler {
    /// Waits for a duration; throws when the waiting task is cancelled.
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let isAdBlockingEnabled: @MainActor () async -> Bool
    private let check: @MainActor () async -> Bool
    private let sleep: Sleeper
    private let now: @MainActor () -> ContinuousClock.Instant
    private let initialDelay: Duration
    private let checkInterval: Duration

    private var task: Task<Void, Never>?
    /// Identifies `task`, so a cancelled loop never clears the state of its replacement.
    private var generation = 0
    private var isStarted = false
    private var isFinished = false
    /// When the last check of this run started.
    private(set) var lastCheck: ContinuousClock.Instant?

    /// - Parameters:
    ///   - isAdBlockingEnabled: the ad-blocking switch, read before each check.
    ///   - check: one update check; false stops the scheduler for good.
    public init(
        initialDelay: Duration = AdBlockRulesetUpdateConfiguration.initialDelay,
        checkInterval: Duration = AdBlockRulesetUpdateConfiguration.checkInterval,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        isAdBlockingEnabled: @escaping @MainActor () async -> Bool,
        check: @escaping @MainActor () async -> Bool
    ) {
        self.initialDelay = initialDelay
        self.checkInterval = checkInterval
        self.sleep = sleep
        self.now = now
        self.isAdBlockingEnabled = isAdBlockingEnabled
        self.check = check
    }

    /// True while a check is pending or running.
    public var isScheduled: Bool { task != nil }

    /// Starts the schedule: the first check `initialDelay` from now (if the switch is on then).
    public func start() {
        guard !isStarted, !isFinished else { return }
        isStarted = true
        schedule()
    }

    /// The user switched ad blocking on or off (plan B88). Off cancels the pending check; on
    /// schedules one unless one is pending already.
    public func adBlockingChanged(isOn: Bool) {
        guard isStarted, !isFinished else { return }
        if isOn {
            if task == nil { schedule() }
        } else {
            cancelTask()
        }
    }

    /// Ends the schedule for good (engine shutdown).
    public func stop() {
        isFinished = true
        cancelTask()
    }

    /// How long until the next check may run: at least `initialDelay`, and not before
    /// `checkInterval` has passed since the last one.
    func delayUntilNextCheck() -> Duration {
        guard let lastCheck else { return initialDelay }
        let remaining = checkInterval - lastCheck.duration(to: now())
        return max(initialDelay, remaining)
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func schedule() {
        generation += 1
        let id = generation
        let firstDelay = delayUntilNextCheck()
        task = Task { [weak self, sleep, checkInterval] in
            var delay = firstDelay
            while true {
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled, let self else { return }
                guard await self.isAdBlockingEnabled() else {
                    // Off: no request; `adBlockingChanged(isOn: true)` schedules again.
                    self.finishLoop(id)
                    return
                }
                guard !Task.isCancelled else { return }
                self.lastCheck = self.now()
                guard await self.check() else {
                    self.isFinished = true
                    self.finishLoop(id)
                    return
                }
                delay = checkInterval
            }
        }
    }

    private func finishLoop(_ id: Int) {
        guard id == generation else { return }
        task = nil
    }
}
