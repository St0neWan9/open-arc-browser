import Foundation

// Page capture for the capture tools (plan B51). Spec: docs/arc-spec/06-flows.md §24 (E4,
// observed): region capture copies a dragged rectangle of the visible page (§24.1); full-page
// capture renders the whole page without a selection step (§24.2); portrait mode renders the page
// for a portrait card (§24.3). Bridge: `-[OACTab captureVisibleRect:…]` and
// `-[OACTab captureFullPageWithMaximumAspectRatio:…]` (chromium-bridge/include/OpenArcCore/OACCapture.h).

/// What `BrowserTab.capture(_:)` renders.
public enum PageCaptureArea: Hashable, Sendable {
    /// Part of the visible page, in points in the tab view's coordinates (origin top left, y down),
    /// clipped to the view; nil is the whole visible page. [06 §24.1] observed: the selection.
    case visible(EngineRect?)
    /// The whole document from its top, beyond the viewport. `maximumAspectRatio` (height / width)
    /// keeps only the top of a long page; nil keeps all of it. [06 §24.2] observed (full page);
    /// the ratio is for portrait mode [06 §24.3] (inferred).
    case fullPage(maximumAspectRatio: Double?)
}

extension BrowserTab {
    /// Engines without page capture refuse it.
    public func capture(_ area: PageCaptureArea) async throws -> EngineSnapshot {
        throw EngineError.unsupported("capture")
    }
}

// MARK: - FakeEngine page image

/// The FakeEngine's stand-in page: every pixel encodes its page position, so a test can check
/// that a capture shows exactly the selected part of the page. At 1 pixel per point the pixel at
/// page point (x, y) is red = x mod 256, green = y mod 256, blue = (x / 256 + 16 × (y / 256)) mod
/// 256, opaque.
public enum FakePageImage {
    /// The color the fake page has at a page point.
    public static func color(atX x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x / 256 + 16 * (y / 256)) & 0xFF))
    }

    /// PNG of the page area `x ..< x + width`, `y ..< y + height` (points = pixels).
    static func png(x: Int, y: Int, width: Int, height: Int) -> Data {
        var raw = Data(capacity: (width * 3 + 1) * height)
        for row in 0..<height {
            raw.append(0) // filter: none
            for column in 0..<width {
                let c = color(atX: x + column, y: y + row)
                raw.append(c.red)
                raw.append(c.green)
                raw.append(c.blue)
            }
        }
        return TinyPNG.encodeRGB(raw, width: width, height: height)
    }
}

/// A minimal PNG writer (stored deflate blocks), so OpenArcEngine needs no image framework.
enum TinyPNG {
    /// `filteredRows`: `height` rows of a filter byte plus `width` RGB triples.
    static func encodeRGB(_ filteredRows: Data, width: Int, height: Int) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, no filter, no interlace
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", zlibStored(filteredRows))
        png.appendChunk("IEND", Data())
        return png
    }

    /// zlib stream of stored (uncompressed) deflate blocks.
    static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let isLast = offset + count >= bytes.count
            out.append(isLast ? 1 : 0)
            out.append(UInt8(count & 0xFF))
            out.append(UInt8(count >> 8))
            out.append(UInt8(~count & 0xFF))
            out.append(UInt8((~count >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
        } while offset < bytes.count
        out.appendBigEndian(adler32(bytes))
        return out
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        append(typed)
        appendBigEndian(TinyPNG.crc32(typed))
    }
}
