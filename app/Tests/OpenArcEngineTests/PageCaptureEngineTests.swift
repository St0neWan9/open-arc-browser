import XCTest
import ImageIO
import OpenArcModel
import OpenArcEngine

/// Plan B51: `BrowserTab.capture(_:)` on FakeEngine. Spec: docs/arc-spec/06-flows.md §24.1
/// (region: the dragged rectangle of the visible page, observed), §24.2 (full page, observed) and
/// §24.3 (portrait mode; its height limit is inferred).
final class PageCaptureEngineTests: XCTestCase {
    private func makeTab() async throws -> FakeTab {
        let tab = try await FakeEngine().makeTab(TabConfiguration(profileID: UUID(), initialURL: URL(string: "https://page.example")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// Decodes a PNG and returns its size and the RGB at a pixel.
    private func pixel(_ png: Data, x: Int, y: Int) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (image.width, image.height, Array(buffer[0..<3]))
    }

    /// 06 §24.1: the image is exactly the selected part of the page.
    func testVisibleRectCapturesTheSelection() async throws {
        let tab = try await makeTab()
        let shot = try await tab.capture(.visible(EngineRect(x: 300, y: 40, width: 120, height: 70)))
        XCTAssertEqual(shot.pixelWidth, 120)
        XCTAssertEqual(shot.pixelHeight, 70)
        let topLeft = try pixel(shot.pngData, x: 0, y: 0)
        XCTAssertEqual(topLeft.width, 120)
        XCTAssertEqual(topLeft.height, 70)
        let expected = FakePageImage.color(atX: 300, y: 40)
        XCTAssertEqual(topLeft.rgb, [expected.red, expected.green, expected.blue])
        let bottomRight = try pixel(shot.pngData, x: 119, y: 69)
        let last = FakePageImage.color(atX: 419, y: 109)
        XCTAssertEqual(bottomRight.rgb, [last.red, last.green, last.blue])
        XCTAssertEqual(tab.commands.last, .capture(.visible(EngineRect(x: 300, y: 40, width: 120, height: 70))))
    }

    /// 06 §24.1: a selection is clipped to the visible page; one outside it is refused.
    func testVisibleRectIsClippedToTheViewport() async throws {
        let tab = try await makeTab()
        let clipped = try await tab.capture(.visible(EngineRect(x: 760, y: 580, width: 100, height: 100)))
        XCTAssertEqual([clipped.pixelWidth, clipped.pixelHeight], [40, 20])
        do {
            _ = try await tab.capture(.visible(EngineRect(x: 900, y: 0, width: 10, height: 10)))
            XCTFail("expected invalidArgument")
        } catch let error as EngineError {
            XCTAssertEqual(error, .invalidArgument)
        }
        let whole = try await tab.capture(.visible(nil))
        XCTAssertEqual([whole.pixelWidth, whole.pixelHeight], [800, 600])
    }

    /// 06 §24.2: the full page goes beyond the viewport; 06 §24.3: portrait mode keeps the top.
    func testFullPageGoesBeyondTheViewport() async throws {
        let tab = try await makeTab()
        tab.simulateCaptureSizes(viewport: (800, 600), page: (800, 2400))
        let full = try await tab.capture(.fullPage(maximumAspectRatio: nil))
        XCTAssertEqual([full.pixelWidth, full.pixelHeight], [800, 2400])
        let bottom = try pixel(full.pngData, x: 5, y: 2399)
        let expected = FakePageImage.color(atX: 5, y: 2399)
        XCTAssertEqual(bottom.rgb, [expected.red, expected.green, expected.blue])
        let portrait = try await tab.capture(.fullPage(maximumAspectRatio: 1.25))
        XCTAssertEqual([portrait.pixelWidth, portrait.pixelHeight], [800, 1000])
    }

    func testClosedTabRefusesCapture() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID(), initialURL: nil))
        await engine.closeTab(tab.id)
        do {
            _ = try await tab.capture(.fullPage(maximumAspectRatio: nil))
            XCTFail("expected tabClosed")
        } catch let error as EngineError {
            XCTAssertEqual(error, .tabClosed(tab.id))
        }
    }
}
