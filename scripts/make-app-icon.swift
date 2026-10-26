// Generates the placeholder app icon for Open Arc (app/Bundle/AppIcon.icns).
//
// Our own abstract design: a rounded square with a neutral slate gradient and the
// letters "OA". It is a placeholder until a real icon is designed.
//
// Uses only system frameworks (CoreGraphics, CoreText, ImageIO) and system tools
// (`sips`, `iconutil`). Usage, from the repo root:
//
//     swift scripts/make-app-icon.swift [output.icns]
//
// The default output is app/Bundle/AppIcon.icns.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "app/Bundle/AppIcon.icns"

/// Draws the 1024x1024 master image.
func makeMaster() -> CGImage {
    let size = 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Body inset like the standard macOS icon grid: an 824pt square centred on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.33, blue: 0.38, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Neutral slate gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.56, green: 0.60, blue: 0.66, alpha: 1),
            CGColor(srgbRed: 0.24, green: 0.27, blue: 0.32, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The letters "OA", centred.
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 380, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
        NSAttributedString.Key(kCTKernAttributeName as String): -10,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "OA", attributes: attributes))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: body.midX - bounds.midX, y: body.midY - bounds.midY)
    CTLineDraw(line, ctx)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(tool) \(args.joined(separator: " ")) failed")
    }
    return process.terminationStatus
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("openarc-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: work)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

let master = work.appendingPathComponent("master.png")
writePNG(makeMaster(), to: master)

// The standard iconset sizes: 16, 32, 128, 256, 512 at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path,
                              "--out", iconset.appendingPathComponent(name).path])
    }
}

let output = URL(fileURLWithPath: outputPath)
try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
print(output.path)
