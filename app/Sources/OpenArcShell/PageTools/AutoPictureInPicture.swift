import Foundation
import Combine
import OpenArcEngine
import OpenArcModel

// Automatic Picture in Picture when the user leaves a video tab (plan C15).
// [03 §Advanced] observed toggle "Enable Picture in Picture when you leave a video tab" (on by
// default); [06 §12] observed per-site row "Automatic Picture-In-Picture" (default Allowed), which
// the engine checks. What counts as leaving is inferred: the tab stops being on screen in this
// window (another tab or Space selected, the tab not a pane of the new split). Coming back to the
// tab closes the Picture in Picture window this opened (inferred; a window the page opened itself
// stays).

@MainActor
final class AutoPictureInPicture {
    private weak var sidebar: SidebarViewModel?
    private let isEnabled: () -> Bool
    private var onScreen: Set<UUID> = []
    /// Tabs whose Picture in Picture this opened.
    private var entered: Set<UUID> = []
    private var selection: AnyCancellable?

    init(sidebar: SidebarViewModel, isEnabled: @escaping () -> Bool) {
        self.sidebar = sidebar
        self.isEnabled = isEnabled
        onScreen = sidebar.onScreenTabIDs
        // `@Published` emits before the property changes: the new value comes with the event.
        selection = sidebar.$selectedTabID
            .dropFirst()
            .sink { [weak self] selected in self?.selectionWillChange(to: selected) }
    }

    func stop() {
        selection = nil
    }

    private func selectionWillChange(to selected: UUID?) {
        guard let sidebar else { return }
        let next = sidebar.onScreenTabIDs(selecting: selected)
        let left = onScreen.subtracting(next)
        let returned = next.intersection(entered)
        onScreen = next
        for id in returned {
            entered.remove(id)
            guard let live = sidebar.liveTab(for: id) else { continue }
            sidebar.controller.enqueueTabCommand(live) { await $0.exitPictureInPicture() }
        }
        guard isEnabled() else { return }
        for id in left {
            guard let live = sidebar.liveTab(for: id) else { continue }
            sidebar.controller.enqueueTabCommand(live) { [weak self] tab in
                guard await tab.enterPictureInPicture(automatically: true) else { return }
                self?.entered.insert(id)
            }
        }
    }
}
