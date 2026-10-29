import Foundation
import AppKit
import QuartzCore
import OpenArcPersistence

// Development-build sidebar scroll self test (sidebar performance with a large imported Space).
// With OPENARC_SIDEBAR_SCROLL_SELFTEST=<output file> in a development build (never the release
// bundle id), once the first browser window is up the app scrolls that window's sidebar list from
// top to bottom and back in small steps, one step per main run-loop turn, then selects rows far
// apart, and writes the timings to the output file: counts and milliseconds only, no titles or
// URLs. Run it with OPENARC_DATA_DIR pointing at a throwaway folder. Our own tool; not in the spec.

@MainActor
enum SidebarScrollSelfTest {
    static let environmentKey = "OPENARC_SIDEBAR_SCROLL_SELFTEST"
    /// Wait after the first window registers, so the window is on screen and laid out. Own value.
    static let startDelay: Duration = .seconds(3)
    /// Points per scroll step (a trackpad flick moves about this much per frame). Own value.
    static let step: CGFloat = 60

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
        }
    }

    /// Scrolls and selects, timing each step from the change until the main run loop is free
    /// again (layout and display of the change included).
    static func run(sidebar: SidebarViewModel) async -> String {
        guard let scroller = sidebar.listScroller, let metrics = scroller.metrics else { return "error=no list\n" }
        var lines = [
            "rows=\(sidebar.snapshot.pinned.count + sidebar.snapshot.today.count)",
            "contentHeight=\(Int(metrics.contentHeight))",
            "viewportHeight=\(Int(metrics.viewportHeight))",
        ]
        var scrollTimes: [Double] = []
        // Down `maxSteps` steps (or to the end) and back up to the top.
        let maxSteps = 300
        var offset: CGFloat = 0
        var down = 0
        while offset < metrics.maxOffset, down < maxSteps {
            offset = min(offset + step, metrics.maxOffset)
            scrollTimes.append(await timeTurn { scroller.scroll(toOffset: offset) })
            down += 1
        }
        while offset > 0 {
            offset = max(offset - step, 0)
            scrollTimes.append(await timeTurn { scroller.scroll(toOffset: offset) })
        }
        lines += summary("scroll", scrollTimes)

        let tabs = sidebar.snapshot.pinned.compactMap { item -> UUID? in
            if case .tab(let tab) = item.kind { return tab.id } else { return nil }
        }
        var selectTimes: [Double] = []
        var selected: [UUID] = []
        if !tabs.isEmpty {
            for index in stride(from: 0, to: tabs.count, by: max(1, tabs.count / 40)) {
                selectTimes.append(await timeTurn { sidebar.selectTab(tabs[index]) })
                selected.append(tabs[index])
            }
        }
        // First selection of a bookmark creates its engine tab and starts loading the page.
        lines += summary("select", selectTimes)
        // Selecting tabs that are already live: the sidebar's own cost.
        try? await Task.sleep(for: .seconds(2))
        var reselectTimes: [Double] = []
        for id in selected.prefix(20) {
            reselectTimes.append(await timeTurn { sidebar.selectTab(id) })
        }
        lines += summary("reselect", reselectTimes)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs `change`, then waits until the main run loop has finished the pass that lays out and
    /// draws it (a main-queue block runs after that pass). Returns the elapsed milliseconds.
    private static func timeTurn(_ change: () -> Void) async -> Double {
        let start = CACurrentMediaTime()
        change()
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
        return (CACurrentMediaTime() - start) * 1000
    }

    private static func summary(_ name: String, _ samples: [Double]) -> [String] {
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
