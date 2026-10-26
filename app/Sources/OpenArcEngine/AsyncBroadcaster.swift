import Foundation

/// Fans one sequence of values out to any number of `AsyncStream` subscribers.
///
/// Each `subscribe` call creates an independent stream; terminated subscribers are removed
/// automatically. Thread-safe. Engine implementations (fake or real) use it for event streams.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class AsyncBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var isFinished = false

    public init() {}

    /// Number of live subscribers (useful in tests).
    public var subscriberCount: Int {
        lock.withLock { continuations.count }
    }

    /// New stream. `initial` values are delivered first, before anything yielded later.
    /// If the broadcaster has already finished, the stream contains `initial` and then ends.
    public func subscribe(initial: [Element] = []) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let finished: Bool = lock.withLock {
            // Yield initial values under the lock so no concurrent `yield` can overtake them.
            for value in initial { continuation.yield(value) }
            if !isFinished { continuations[id] = continuation }
            return isFinished
        }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    /// Delivers a value to every live subscriber.
    public func yield(_ value: Element) {
        lock.withLock {
            for continuation in continuations.values { continuation.yield(value) }
        }
    }

    /// Ends every stream; later subscribers get only their initial values.
    public func finish() {
        let toFinish: [AsyncStream<Element>.Continuation] = lock.withLock {
            isFinished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in toFinish { continuation.finish() }
    }
}
