import CoreGraphics

/// Where a restored browser window goes (B214): its saved frame, when enough of it is on one of
/// the screens to grab and move it (a display may be gone since). Our own rule.
enum WindowFrameRestore {
    /// How much of the window must be on a screen, in points, both ways.
    static let minimumVisible: CGFloat = 100

    /// `frame` (AppKit screen coordinates) if it overlaps one of `screens` (their visible frames)
    /// by at least `minimumVisible` both ways; nil otherwise or without a frame.
    static func frame(_ frame: CGRect?, screens: [CGRect]) -> CGRect? {
        guard let frame, frame.width > 0, frame.height > 0 else { return nil }
        let isReachable = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width >= minimumVisible && overlap.height >= minimumVisible
        }
        return isReachable ? frame : nil
    }
}
