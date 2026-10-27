import Foundation
import XCTest
@testable import OpenArcEngine

/// Plan B88 (D13 follow-up to C19, docs/release.md §Network use): ad-block filter-list update
/// checks run only while ad blocking is switched on. The switch itself is [00 §A 内核继承]
/// "广告拦截" (observed); the schedule is our design.
@MainActor
final class AdBlockRulesetUpdateSchedulerTests: XCTestCase {
    // MARK: Fixtures

    /// A sleep that waits until the test fires it; cancelling the waiting task ends it with
    /// `CancellationError`, like `Task.sleep`.
    private final class ManualSleeper: @unchecked Sendable {
        // @unchecked: every stored property is read and written only under `lock`.
        private let lock = NSLock()
        private var pending: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
        private var cancelled: Set<Int> = []
        private var nextID = 0
        private var requestedLog: [Duration] = []

        /// Every duration asked for, in order.
        var requested: [Duration] { lock.withLock { requestedLog } }
        var pendingCount: Int { lock.withLock { pending.count } }

        func sleep(_ duration: Duration) async throws {
            let id: Int = lock.withLock {
                nextID += 1
                requestedLog.append(duration)
                return nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let alreadyCancelled: Bool = lock.withLock {
                        if cancelled.contains(id) { return true }
                        pending.append((id, continuation))
                        return false
                    }
                    if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                    cancelled.insert(id)
                    guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
                    return pending.remove(at: index).continuation
                }
                continuation?.resume(throwing: CancellationError())
            }
        }

        /// Ends the oldest pending sleep normally.
        func fire() {
            let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst().continuation }
            continuation?.resume()
        }
    }

    /// Counts every request the updater makes; serves nothing (each check fails at the manifest).
    private final class RecordingFetcher: AdBlockRulesetFetching, @unchecked Sendable {
        // @unchecked: `log` is read and written only under `lock`.
        private let lock = NSLock()
        private var log: [URL] = []
        var requests: [URL] { lock.withLock { log } }

        func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
            lock.withLock { log.append(url) }
            throw AdBlockRulesetUpdateError.download("404 \(url)")
        }
    }

    private let initialDelay: Duration = .seconds(30)
    private let checkInterval: Duration = .seconds(24 * 60 * 60)
    private var sleeper: ManualSleeper!
    private var fetcher: RecordingFetcher!
    private var blocker: FakeAdBlocking!
    private var clock: ContinuousClock.Instant!
    private var checkResult = true

    override func setUp() async throws {
        sleeper = ManualSleeper()
        fetcher = RecordingFetcher()
        blocker = FakeAdBlocking(rulesetVersion: "20261027-aaaaaa")
        clock = ContinuousClock.now
        checkResult = true
    }

    private func makeScheduler() -> AdBlockRulesetUpdateScheduler {
        let updater = AdBlockRulesetUpdater(
            manifestURL: URL(string: "http://127.0.0.1:8765/adblock/manifest.json")!,
            store: AdBlockRulesetStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("openarc-b88-\(UUID().uuidString)", isDirectory: true)),
            fetcher: fetcher
        )
        let sleeper = sleeper!
        let blocker = blocker!
        return AdBlockRulesetUpdateScheduler(
            initialDelay: initialDelay, checkInterval: checkInterval,
            sleep: { try await sleeper.sleep($0) },
            now: { [unowned self] in self.clock },
            isAdBlockingEnabled: { await blocker.isEnabled() },
            check: { [unowned self] in
                _ = await updater.check(activeVersion: await blocker.rulesetVersion())
                return self.checkResult
            }
        )
    }

    /// Lets the scheduler's task run until `condition` holds (bounded).
    private func settle(until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    /// Lets queued work run without waiting for a condition (for "nothing happens" checks).
    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    // MARK: Tests

    /// B88: with ad blocking off no update request goes out; switching it on runs a check.
    func testNoRequestWhileAdBlockingIsOff() async {
        await blocker.setEnabled(false)
        let scheduler = makeScheduler()
        scheduler.start()
        await settle { sleeper.pendingCount == 1 }
        XCTAssertEqual(sleeper.requested, [initialDelay])
        sleeper.fire()
        await settle { !scheduler.isScheduled }
        await drain()
        XCTAssertEqual(fetcher.requests, [], "no rule-update request while ad blocking is off")

        await blocker.setEnabled(true)
        scheduler.adBlockingChanged(isOn: true)
        await settle { sleeper.pendingCount == 1 }
        XCTAssertEqual(sleeper.requested.last, initialDelay)
        sleeper.fire()
        await settle { !fetcher.requests.isEmpty }
        XCTAssertEqual(fetcher.requests.first?.lastPathComponent, "manifest.json")
        scheduler.stop()
    }

    /// B88: switching ad blocking off cancels the pending check; on again keeps the interval
    /// since the last check (no extra request from toggling).
    func testTurningOffCancelsAndTurningOnKeepsTheInterval() async {
        let scheduler = makeScheduler()
        scheduler.start()
        await settle { sleeper.pendingCount == 1 }
        sleeper.fire()
        await settle { fetcher.requests.count == 1 && sleeper.pendingCount == 1 }
        XCTAssertEqual(sleeper.requested, [initialDelay, checkInterval])

        await blocker.setEnabled(false)
        scheduler.adBlockingChanged(isOn: false)
        XCTAssertFalse(scheduler.isScheduled)
        await settle { sleeper.pendingCount == 0 }
        await drain()
        XCTAssertEqual(fetcher.requests.count, 1)

        // One hour later the user turns it back on: the next check waits out the day.
        clock = clock.advanced(by: .seconds(60 * 60))
        await blocker.setEnabled(true)
        scheduler.adBlockingChanged(isOn: true)
        await settle { sleeper.pendingCount == 1 }
        XCTAssertEqual(sleeper.requested.last, checkInterval - .seconds(60 * 60))
        // A second "on" does not add a second pending check.
        scheduler.adBlockingChanged(isOn: true)
        await drain()
        XCTAssertEqual(sleeper.pendingCount, 1)

        // A day after the last check, turning on waits only the initial delay.
        scheduler.adBlockingChanged(isOn: false)
        await settle { sleeper.pendingCount == 0 }
        clock = clock.advanced(by: checkInterval)
        scheduler.adBlockingChanged(isOn: true)
        await settle { sleeper.pendingCount == 1 }
        XCTAssertEqual(sleeper.requested.last, initialDelay)
        sleeper.fire()
        await settle { fetcher.requests.count == 2 }
        scheduler.stop()
        await settle { sleeper.pendingCount == 0 }
    }

    /// The switch is read before each check, so a change made without `adBlockingChanged` (the
    /// engine's own preference) still stops requests.
    func testSwitchIsReadBeforeEachCheck() async {
        let scheduler = makeScheduler()
        scheduler.start()
        await settle { sleeper.pendingCount == 1 }
        sleeper.fire()
        await settle { fetcher.requests.count == 1 && sleeper.pendingCount == 1 }
        await blocker.setEnabled(false)
        sleeper.fire()
        await settle { !scheduler.isScheduled }
        await drain()
        XCTAssertEqual(fetcher.requests.count, 1)
    }

    /// Before `start()` (engine not up) and after `stop()` or a check that ends the updates,
    /// switch changes schedule nothing.
    func testNothingRunsOutsideStartAndStop() async {
        let scheduler = makeScheduler()
        scheduler.adBlockingChanged(isOn: true)
        await drain()
        XCTAssertFalse(scheduler.isScheduled)
        XCTAssertEqual(sleeper.requested, [])

        checkResult = false
        scheduler.start()
        await settle { sleeper.pendingCount == 1 }
        sleeper.fire()
        await settle { !scheduler.isScheduled }
        scheduler.adBlockingChanged(isOn: true)
        XCTAssertFalse(scheduler.isScheduled, "a check that reports stop ends the schedule")

        let other = makeScheduler()
        other.start()
        other.stop()
        other.adBlockingChanged(isOn: true)
        other.start()
        XCTAssertFalse(other.isScheduled)
        await settle { sleeper.pendingCount == 0 }
        XCTAssertEqual(fetcher.requests.count, 1)
    }
}
