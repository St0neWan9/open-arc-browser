import Foundation
import os
import OpenArcSyncAPI

/// Fans the current `SyncStatus` out to any number of subscribers. Each new stream starts with the
/// current value. Streams end when the subscriber cancels.
final class StatusBroadcaster: Sendable {
    private struct State {
        var current: SyncStatus
        var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(initial: SyncStatus) {
        state = OSAllocatedUnfairLock(initialState: State(current: initial))
    }

    var current: SyncStatus {
        state.withLock { $0.current }
    }

    func stream() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        // Yield under the lock so a concurrent publish cannot overtake the initial value.
        state.withLock { s in
            s.continuations[id] = continuation
            continuation.yield(s.current)
        }
        return stream
    }

    /// Publishes a new status; no-op if unchanged.
    func publish(_ status: SyncStatus) {
        state.withLock { s in
            guard s.current != status else { return }
            s.current = status
            for continuation in s.continuations.values {
                continuation.yield(status)
            }
        }
    }

    var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }
}
