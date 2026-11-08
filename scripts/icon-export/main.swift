import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let output = root.appendingPathComponent("branding/icons")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let work = fm.temporaryDirectory.appendingPathComponent("openarc-iconset-\(UUID().uuidString)")
try fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }
func writePNG(_ image: CGImage, _ url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot create PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Cannot save PNG") }
}
func run(_ command: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Export failed: \(command)") }
}
let filenames = ["original", "candy", "neon", "fluted-glass", "paper", "spectrum"]
for (index, variant) in AppIconArtwork.variants.enumerated() {
    let name = filenames[index]
    let master = AppIconArtwork.render(variant, pixels: 1024)!
    try writePNG(master, output.appendingPathComponent("\(name).png"))
    let iconset = work.appendingPathComponent("\(name).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let filename = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            // Render each size directly for crisp silhouettes and material detail.
            try writePNG(AppIconArtwork.render(variant, pixels: base * scale)!, iconset.appendingPathComponent(filename))
        }
    }
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("\(name).icns").path])
}
let bundle = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : root.appendingPathComponent("app/Bundle/AppIcon.icns")
try fm.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(contentsOf: output.appendingPathComponent("original.icns")).write(to: bundle)
try AppIconArtwork.svg().write(to: root.appendingPathComponent("branding/open-arc.svg"), atomically: true, encoding: .utf8)
if let websiteDirectory = ProcessInfo.processInfo.environment["OPENARC_WEBSITE_DIR"], !websiteDirectory.isEmpty {
    let assets = URL(fileURLWithPath: websiteDirectory).appendingPathComponent("assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    try AppIconArtwork.svg().write(to: assets.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
    try writePNG(AppIconArtwork.render("slate", pixels: 256)!, assets.appendingPathComponent("app-icon.png"))
}

// Contact sheet, including a small preview at the settings row's actual icon size.
let width = 1500, height = 1140
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(AppIconArtwork.color(0xF8F6FB)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
@MainActor
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: UInt32) {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): AppIconArtwork.color(color)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs))
    ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
}
text("Open Arc", x: 80, y: 1050, size: 38, color: 0x38314F)
text("One ribbon. Six expressions.", x: 80, y: 1008, size: 22, color: 0x898099)
for (index, variant) in AppIconArtwork.variants.enumerated() {
    let x = CGFloat(65 + (index % 3) * 480), y = CGFloat(570 - (index / 3) * 475)
    ctx.draw(AppIconArtwork.render(variant, pixels: 512)!, in: CGRect(x: x + 38, y: y + 55, width: 350, height: 350))
    ctx.draw(AppIconArtwork.render(variant, pixels: 104)!, in: CGRect(x: x + 90, y: y - 3, width: 52, height: 52))
    text(AppIconArtwork.names[index], x: x + 155, y: y + 15, size: 25, color: 0x38314F)
}
try writePNG(ctx.makeImage()!, root.appendingPathComponent("branding/icon-collection.png"))
print("Exported six PNG/ICNS variants, the bundle icon, SVG mark and contact sheet.")
