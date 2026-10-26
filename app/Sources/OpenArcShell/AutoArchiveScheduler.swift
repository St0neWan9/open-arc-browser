import Foundation

/// Source of periodic ticks. Injectable so tests drive the scheduler without sleeping.
public protocol AutoArchiveTicker: Sendable {
    /// A stream that yields once per `interval` seconds until the consuming task is cancelled.
    func ticks(every interval: TimeInterval) -> AsyncStream<Void>
}

/// Real-time ticker backed by `Task.sleep`.
public struct SystemAutoArchiveTicker: AutoArchiveTicker {
    public init() {}

    public func ticks(every interval: TimeInterval) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
                    if Task.isCancelled { break }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Runs an action once at start (launch) and then on every tick (hourly by default).
/// [05 §window and app entry points] observed: tabs are auto-archived after 12 hours by
/// default; the hourly cadence is inferred (the spec gives the lifetime, not the check period).
@MainActor
public final class AutoArchiveScheduler {
    public static let defaultInterval: TimeInterval = 60 * 60

    private let interval: TimeInterval
    private let ticker: any AutoArchiveTicker
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?

    public var isRunning: Bool { task != nil }

    public init(
        interval: TimeInterval = AutoArchiveScheduler.defaultInterval,
        ticker: any AutoArchiveTicker = SystemAutoArchiveTicker(),
        action: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.ticker = ticker
        self.action = action
    }

    /// Runs the action immediately, then on every tick. Does nothing if already running.
    public func start() {
        guard task == nil else { return }
        action()
        let stream = ticker.ticks(every: interval)
        task = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                self.action()
            }
        }
    }

    /// Cancels the tick loop. The scheduler can be started again afterwards.
    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
