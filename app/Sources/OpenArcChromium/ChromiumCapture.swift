import Foundation
import CoreGraphics
import OpenArcEngine
import OpenArcCore

// Page capture (plan B51, docs/arc-spec/06-flows.md §24) on the bridge's `OACTab (OACCapture)`
// category: the visible page through the view's surface copy, the full page through the DevTools
// protocol's `Page.captureScreenshot` with `captureBeyondViewport`.

extension ChromiumTabCore {
    func capture(_ area: PageCaptureArea) async throws -> EngineSnapshot {
        guard let tab, !tab.isClosed else { throw EngineError.tabClosed(id) }
        let id = self.id
        return try await withCheckedThrowingContinuation { continuation in
            let done: @Sendable (Data?, CGSize, (any Error)?) -> Void = { png, size, error in
                if let png {
                    continuation.resume(returning: EngineSnapshot(
                        pngData: png, pixelWidth: Int(size.width), pixelHeight: Int(size.height)
                    ))
                } else {
                    continuation.resume(throwing: error.map { EngineError(bridge: $0, tabID: id) } ?? EngineError.snapshotUnavailable)
                }
            }
            switch area {
            case .visible(let rect):
                let cgRect = rect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .null
                tab.captureVisible(rect: cgRect, completionHandler: done)
            case .fullPage(let ratio):
                tab.captureFullPage(maximumAspectRatio: ratio ?? 0, completionHandler: done)
            }
        }
    }
}
