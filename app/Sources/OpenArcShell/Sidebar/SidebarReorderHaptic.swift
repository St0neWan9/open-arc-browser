import AppKit

/// The trackpad tap of a sidebar reorder (B68, see `SidebarViewModel.playReorderHaptic`). The
/// alignment pattern is the one macOS uses when a dragged item snaps into place; our choice.
@MainActor
enum SidebarReorderHaptic {
    static func play() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
