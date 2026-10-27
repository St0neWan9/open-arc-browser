import AppKit
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcDesign

// Image intake for the Easel (B56): file picker and pasteboard, downsized and encoded so the bytes
// fit inline in the element record (`EaselImage.maxEncodedBytes`, see Easel.swift for the decision).

enum EaselImageEncoder {
    /// Encodes `image` for inline storage: scaled so its longest side is at most
    /// `Metrics.Easel.maxStoredImagePixels`, PNG when that fits the limit, else JPEG at falling
    /// quality and size until it fits. nil when nothing fits.
    static func encode(_ image: NSImage) -> EaselImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var side = min(Metrics.Easel.maxStoredImagePixels, Double(max(source.width, source.height)))
        for _ in 0..<6 {
            guard let bitmap = scaled(source, longestSide: side) else { return nil }
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= EaselImage.maxEncodedBytes {
                return EaselImage(data: png, format: .png, pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
            }
            for quality in [0.85, 0.7, 0.55] {
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   jpeg.count <= EaselImage.maxEncodedBytes {
                    return EaselImage(data: jpeg, format: .jpeg, pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
                }
            }
            side *= 0.7
        }
        return nil
    }

    private static func scaled(_ source: CGImage, longestSide: Double) -> NSBitmapImageRep? {
        let scale = min(1, longestSide / Double(max(source.width, source.height, 1)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The open panel for the image tool.
    @MainActor
    static func pickImageFile() -> EaselImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return nil }
        return encode(image)
    }

    /// ⌘V content: an image (file or image data) first, else plain text.
    @MainActor
    static func readPasteboard(_ pasteboard: NSPasteboard = .general) -> EaselPasteContent? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url), let encoded = encode(image) {
            return .image(encoded)
        }
        if let image = NSImage(pasteboard: pasteboard), let encoded = encode(image) {
            return .image(encoded)
        }
        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        }
        return nil
    }
}
