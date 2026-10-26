import Foundation
import OpenArcModel
import OpenArcSyncAPI

extension WorkspaceStore {
    /// Subscribes to changes and returns the workspace at the moment of subscribing, in one actor
    /// step. A consumer that diffs its baseline against `current` and then reads `events` misses no
    /// change: everything after `current` arrives on the stream.
    public func subscribe() -> (current: WorkspaceState, events: AsyncStream<WorkspaceStoreEvent>) {
        (workspace, events())
    }
}
