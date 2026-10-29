import Foundation
import AppKit
import QuartzCore
import OpenArcPersistence

// Development-build sidebar performance self test (sidebar performance with a large imported
// Space). With OPENARC_SIDEBAR_SCROLL_SELFTEST=<output file> in a development build (never the
// release bundle id), once the first browser window is up the app runs these on that window's
// sidebar, one change per main run-loop turn, and writes the timings to the output file (counts
// and milliseconds only, no titles or URLs):
// - scroll: the list from top to bottom and back in small steps;
// - hover: the pointer entering and leaving rows (the view model's part; the row's own hover
//   fill is local to that row);
// - select / reselect: rows far apart, first while their tabs are not live, then again;
// - folder: expanding and collapsing top-level folders;
// - space: switching to another Space and back, the slide animation's frames included;
// - fling: five seconds of display-synchronized scrolling, counting late frames.
// Run it with OPENARC_DATA_DIR pointing at a throwaway folder. Our own tool; not in the spec.

@MainActor
enum SidebarScrollSelfTest {
    static let environmentKey = "OPENARC_SIDEBAR_SCROLL_SELFTEST"
    /// Set to 1 to quit the app once the report is written (unattended runs).
    static let quitEnvironmentKey = "OPENARC_SIDEBAR_SCROLL_SELFTEST_QUIT"
    /// Set to one phase name (scroll, hover, select, folder, space, fling) to run only that phase,
    /// `repeatEnvironmentKey` times (default 1): a steady load for a profiler.
    static let phaseEnvironmentKey = "OPENARC_SIDEBAR_SCROLL_SELFTEST_PHASE"
    static let repeatEnvironmentKey = "OPENARC_SIDEBAR_SCROLL_SELFTEST_REPEAT"
    /// Wait after the first window registers, so the window is on screen and laid out. Own value.
    static let startDelay: Duration = .seconds(3)
    /// Points per scroll step (a trackpad flick moves about this much per frame). Own value.
    static let step: CGFloat = 60
    /// Fling speed in points per second and its length. Own values: a fast two-finger fling.
    static let flingSpeed: CGFloat = 3000
    static let flingDuration: Double = 5

    private static var didStart = false

    /// The output file, or nil (release build, or no variable set).
    static func outputURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String = PersistenceDefaults.bundleIdentifier
    ) -> URL? {
        guard bundleIdentifier != PersistenceDefaults.releaseBundleIdentifier,
              let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Starts the run once per launch, for this window's sidebar.
    static func startIfRequested(sidebar: SidebarViewModel) {
        guard !didStart, let output = outputURL() else { return }
        didStart = true
        try? "started\n".write(to: output.appendingPathExtension("progress"), atomically: true, encoding: .utf8)
        Task { @MainActor [weak sidebar] in
            try? await Task.sleep(for: startDelay)
            guard let sidebar else {
                try? "error=no sidebar\n".write(to: output, atomically: true, encoding: .utf8)
                return
            }
            let report = await run(sidebar: sidebar)
            try? report.write(to: output, atomically: true, encoding: .utf8)
            // The data folder is a throwaway one: no quit confirmation, no final save.
            if ProcessInfo.processInfo.environment[quitEnvironmentKey] == "1" { exit(0) }
        }
    }

    /// Runs every measurement (or, with `phaseEnvironmentKey`, one phase `repeatEnvironmentKey`
    /// times, for a profiler), timing each change from the change until the main run loop is free
    /// again (layout and display of the change included).
    static func run(sidebar: SidebarViewModel) async -> String {
        guard let scroller = sidebar.listScroller, let metrics = scroller.metrics else { return "error=no list\n" }
        // The window's content view: it stays while the list is rebuilt per Space.
        let windowView = (scroller as? SidebarNSScrollHook)?.scrollView?.window?.contentView
        let environment = ProcessInfo.processInfo.environment
        let only = environment[phaseEnvironmentKey]
        let repeats = only == nil ? 1 : max(1, Int(environment[repeatEnvironmentKey] ?? "") ?? 1)
        var lines = [
            "rows=\(sidebar.snapshot.pinned.count + sidebar.snapshot.today.count)",
            "contentHeight=\(Int(metrics.contentHeight))",
            "viewportHeight=\(Int(metrics.viewportHeight))",
        ]
        let phases: [(String, () async -> [String])] = [
            ("micro", { micro(sidebar: sidebar) }),
            ("scroll", { await scroll(sidebar: sidebar, windowView: windowView) }),
            ("hover", { await hover(sidebar: sidebar, windowView: windowView) }),
            ("select", { await select(sidebar: sidebar, windowView: windowView) }),
            ("folder", { await folders(sidebar: sidebar, windowView: windowView) }),
            ("space", { await spaceSwitch(sidebar: sidebar, windowView: windowView) }),
            ("fling", { await fling(sidebar: sidebar, windowView: windowView) }),
        ]
        for (name, phase) in phases where only == nil || only == name {
            for _ in 0..<repeats { lines += await phase() }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Costs of the derivations a change runs on the main thread, in this (optimized) build.
    private static func micro(sidebar: SidebarViewModel) -> [String] {
        func time(_ name: String, runs: Int = 21, _ body: () -> Void) -> String {
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = CACurrentMediaTime()
                body()
                samples.append((CACurrentMediaTime() - start) * 1000)
            }
            return String(format: "micro.\(name)Ms=%.3f", samples.sorted()[runs / 2])
        }
        let workspace = sidebar.workspace
        var changed = workspace
        if let id = sidebar.snapshot.pinned.first?.id, changed.tabs[id] != nil { changed.tabs[id]?.lastActiveAt = Date() }
        let snapshot = sidebar.snapshot
        return [
            time("snapshotMake") { _ = SidebarSnapshot.make(workspace: workspace, spaceID: sidebar.selectedSpaceID, profileID: sidebar.currentProfileID) },
            time("listGeometry") { _ = SidebarListGeometry(snapshot: snapshot) },
            time("workspaceEquals") { _ = workspace == changed },
            time("selectedListRowID") { _ = sidebar.selectedListRowID },
        ]
    }

    /// The list from the top down `maxSteps` steps (or to the end) and back up to the top.
    private static func scroll(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        guard let scroller = sidebar.listScroller, let metrics = scroller.metrics else { return ["scroll.error=no list scroller"] }
        let times = Recorder("scroll", windowView: windowView)
        let maxSteps = 300
        var offset: CGFloat = 0
        var down = 0
        scroller.scroll(toOffset: 0)
        while offset < metrics.maxOffset, down < maxSteps {
            offset = min(offset + step, metrics.maxOffset)
            await times.time { scroller.scroll(toOffset: offset) }
            down += 1
        }
        while offset > 0 {
            offset = max(offset - step, 0)
            await times.time { scroller.scroll(toOffset: offset) }
        }
        return times.lines()
    }

    /// Selects rows far apart: first while their tabs are not live (the first selection of a
    /// bookmark creates its engine tab and starts loading the page), then again once they are
    /// (the sidebar's own cost).
    private static func select(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        let tabs = sidebar.snapshot.pinned.compactMap { item -> UUID? in
            if case .tab(let tab) = item.kind { return tab.id } else { return nil }
        }
        let first = Recorder("select", windowView: windowView)
        var selected: [UUID] = []
        for index in stride(from: 0, to: tabs.count, by: max(1, tabs.count / 40)) {
            await first.time { sidebar.selectTab(tabs[index]) }
            selected.append(tabs[index])
        }
        let firstLines = first.lines()
        try? await Task.sleep(for: .seconds(2))
        let again = Recorder("reselect", windowView: windowView)
        for id in selected.prefix(20) {
            await again.time { sidebar.selectTab(id) }
        }
        return firstLines + again.lines()
    }

    /// Pointer entering a row and leaving it again, for rows across the visible list.
    private static func hover(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        let ids = sidebar.snapshot.pinned.prefix(20).compactMap { item -> UUID? in
            if case .tab(let tab) = item.kind { return tab.id } else { return nil }
        }
        let times = Recorder("hover", windowView: windowView)
        for id in ids {
            await times.time { sidebar.hoverBegan(id) }
            await times.time { sidebar.hoverEnded(id) }
        }
        return times.lines()
    }

    /// Expands and collapses the first top-level folders (each twice, so the state ends as found).
    private static func folders(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        let ids = sidebar.snapshot.pinned.compactMap { item -> UUID? in
            if case .folder(let folder) = item.kind, item.depth == 0 { return folder.id } else { return nil }
        }.prefix(10)
        let times = Recorder("folder", windowView: windowView)
        for id in ids {
            await times.time { sidebar.toggleFolder(id) }
            await times.time { sidebar.toggleFolder(id) }
        }
        return times.lines()
    }

    /// Switches to another Space and back a few times. Each recorder's late-frame count covers
    /// its switches and their slides (≈ 0.3 s on the observed spring).
    private static func spaceSwitch(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        guard let large = sidebar.selectedSpaceID,
              let other = sidebar.dockSpaces.first(where: { $0.id != large })?.id else { return ["space.count=0"] }
        let away = Recorder("spaceAway", windowView: windowView)
        let back = Recorder("spaceBack", windowView: windowView)
        for _ in 0..<5 {
            await away.time { sidebar.selectSpace(other) }
            try? await Task.sleep(for: .milliseconds(500))
            await back.time { sidebar.selectSpace(large) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return away.lines() + back.lines()
    }

    /// Scrolls at `flingSpeed` once per display frame for `flingDuration` seconds, bouncing at the
    /// ends, and counts the frames whose callback came late (a dropped frame).
    private static func fling(sidebar: SidebarViewModel, windowView: NSView?) async -> [String] {
        guard let hook = sidebar.listScroller as? SidebarNSScrollHook else { return ["fling.error=no list scroller"] }
        guard hook.scrollView != nil else { return ["fling.error=list scroller has no scroll view"] }
        guard let monitor = SidebarFrameMonitor(view: windowView) else { return ["fling.error=no window"] }
        hook.scroll(toOffset: 0)
        var offset: CGFloat = 0, direction: CGFloat = 1
        var last: CFTimeInterval?
        monitor.onFrame = { timestamp in
            guard let metrics = hook.metrics else { return }
            let dt = last.map { timestamp - $0 } ?? 0
            last = timestamp
            offset += direction * flingSpeed * CGFloat(dt)
            if offset >= metrics.maxOffset { offset = metrics.maxOffset; direction = -1 }
            if offset <= 0 { offset = 0; direction = 1 }
            hook.scroll(toOffset: offset)
        }
        monitor.start()
        try? await Task.sleep(for: .seconds(flingDuration))
        return monitor.stop().lines("fling")
    }

    /// Wall and main-thread CPU milliseconds of one change (`timeTurn`).
    struct Turn {
        var wall: Double
        var cpu: Double
        /// CPU milliseconds of the change call itself (the model work before any view update).
        var model: Double
    }

    /// Timings of one kind of change, and the display frames that came late while they ran.
    @MainActor
    final class Recorder {
        let name: String
        private var turns: [Turn] = []
        private let monitor: SidebarFrameMonitor?

        init(_ name: String, windowView: NSView?) {
            self.name = name
            monitor = SidebarFrameMonitor(view: windowView)
            monitor?.start()
        }

        func time(_ change: () -> Void) async {
            turns.append(await timeTurn(change))
        }

        func lines() -> [String] {
            let frames = monitor?.stop()
            return summary(name, turns.map(\.wall)) + summary("\(name).cpu", turns.map(\.cpu))
                + summary("\(name).model", turns.map(\.model))
                + ["\(name).dropped=\(frames?.dropped ?? -1)"]
        }
    }

    /// Runs `change`, then waits until the main run loop has finished the pass that lays out and
    /// draws it (a main-queue block runs after that pass). Wall time includes waiting for the
    /// render server to take the frame; CPU time is the main thread's own work.
    private static func timeTurn(_ change: () -> Void) async -> Turn {
        let start = CACurrentMediaTime()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        change()
        let modelCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        return Turn(wall: (CACurrentMediaTime() - start) * 1000, cpu: cpu, model: modelCPU)
    }

    nonisolated fileprivate static func summary(_ name: String, _ samples: [Double]) -> [String] {
        guard !samples.isEmpty else { return ["\(name).count=0"] }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let over16 = samples.filter { $0 > 16.7 }.count
        return [
            "\(name).count=\(samples.count)",
            String(format: "\(name).p50Ms=%.2f", percentile(0.5)),
            String(format: "\(name).p95Ms=%.2f", percentile(0.95)),
            String(format: "\(name).maxMs=%.2f", sorted.last!),
            "\(name).over16ms=\(over16)",
        ]
    }
}

/// Display-synchronized frame callbacks of one view's screen, recording the interval between
/// consecutive callbacks. A callback that comes more than 1.5 frame durations after the previous
/// one means the main thread missed a frame.
@MainActor
final class SidebarFrameMonitor: NSObject {
    struct Result {
        var intervals: [Double] = []
        /// Main-thread CPU milliseconds between consecutive callbacks.
        var frameCPU: [Double] = []
        var frameDuration: Double = 1.0 / 60
        var dropped = 0

        func lines(_ name: String) -> [String] {
            SidebarScrollSelfTest.summary("\(name).interval", intervals.map { $0 * 1000 })
                + SidebarScrollSelfTest.summary("\(name).frameCPU", frameCPU)
                + [String(format: "\(name).frameMs=%.2f", frameDuration * 1000), "\(name).dropped=\(dropped)"]
        }
    }

    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var previousCPU: UInt64 = 0
    private var result = Result()
    /// Called on every frame with the frame's timestamp.
    var onFrame: ((CFTimeInterval) -> Void)?

    init?(view: NSView?) {
        guard let view else { return nil }
        super.init()
        link = view.displayLink(target: self, selector: #selector(frame(_:)))
    }

    func start() {
        link?.add(to: .main, forMode: .common)
    }

    func stop() -> Result {
        link?.invalidate()
        link = nil
        return result
    }

    @objc private func frame(_ link: CADisplayLink) {
        let duration = link.targetTimestamp - link.timestamp
        if duration > 0 { result.frameDuration = duration }
        let cpuNow = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if let previous {
            let interval = link.timestamp - previous
            result.intervals.append(interval)
            // Main-thread CPU between two callbacks: our work for that frame, not idle waiting.
            result.frameCPU.append(Double(cpuNow - previousCPU) / 1_000_000)
            if interval > result.frameDuration * 1.5 { result.dropped += Int((interval / result.frameDuration).rounded()) - 1 }
        }
        previous = link.timestamp
        previousCPU = cpuNow
        onFrame?(link.timestamp)
    }
}
