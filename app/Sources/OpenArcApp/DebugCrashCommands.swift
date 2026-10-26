import SwiftUI
import OpenArcShell

// Debug ▸ Crash (plan D8): crashes on purpose to check that local crash reports are written to
// `<app data dir>/Crash Reports` (decision Q8: never uploaded). Shown only in the development
// build started with `OPENARC_DEBUG_CRASH=1` (`CrashReportLocation.isDebugCrashMenuEnabled`).
// Our own menu; not in the spec.

struct DebugCrashCommands: Commands {
    /// The key browser window's model, for the page crashes (they load a Chromium debug URL in
    /// the selected tab).
    @FocusedObject private var focused: ShellModel?

    var body: some Commands {
        CommandMenu("Debug") {
            // The app process is Chromium's browser process: Crashpad's handler, started by the
            // engine, takes this Swift trap through the task's exception port.
            Button("Crash") { DebugCrash.crashAppProcess() }
            Divider()
            Button("Crash Page Renderer") { load("chrome://crash") }
                .disabled(focused == nil)
            Button("Crash GPU Process") { load("chrome://gpucrash") }
                .disabled(focused == nil)
        }
    }

    /// Debug URLs never commit; Chromium handles them when they are typed, which is how the
    /// bridge loads every URL.
    private func load(_ string: String) {
        guard let focused, let url = URL(string: string) else { return }
        focused.sidebar.navigateSelectedTab(to: url)
    }
}

enum DebugCrash {
    /// A Swift runtime trap, like a failed force unwrap.
    static func crashAppProcess() -> Never {
        fatalError("Debug ▸ Crash (OPENARC_DEBUG_CRASH)")
    }
}
