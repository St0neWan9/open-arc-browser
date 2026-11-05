import Foundation
import CoreGraphics

/// Shared production artwork for the app, website and exported icon files.
/// Coordinates use a top-left origin; the three ribbons also form the SVG master.
enum AppIconArtwork {
    static let variants = ["slate", "sunrise", "night", "lagoon", "paper", "prism"]
    static let names = ["Original", "Candy", "Neon", "Fluted Glass", "Paper", "Spectrum"]
    static let ribbons = [
        "M 351 128 C 399 75 450 55 489 94 C 533 155 582 245 620 316 C 647 362 630 394 597 413 L 451 289 Z",
        "M 211 359 C 290 312 371 288 451 289 C 529 286 596 297 620 316 C 650 340 638 382 605 409 C 568 440 512 447 447 439 C 351 429 277 393 214 416 L 183 428 Z",
        "M 0 467 C 44 357 92 245 148 143 C 199 52 259 0 333 0 C 398 0 450 36 489 94 C 450 55 399 75 351 128 C 270 217 208 370 169 467 Z"
    ]

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static func path(_ data: String) -> CGPath {
        let tokens = data.split(separator: " ")
        var i = 0
        func point() -> CGPoint {
            let p = CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
            i += 2
            return p
        }
        let result = CGMutablePath()
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": result.move(to: point())
            case "L": result.addLine(to: point())
            case "C":
                let a = point(), b = point(), end = point()
                result.addCurve(to: end, control1: a, control2: b)
            case "Z": result.closeSubpath()
            default: preconditionFailure("Invalid artwork command")
            }
        }
        return result
    }

    static func palette(_ variant: String) -> (tile: [UInt32], ribbons: [[UInt32]]) {
        switch variant {
        case "sunrise": return ([0xFBE3ED, 0xE8BED8], [[0xFFADBD, 0xF26D95], [0xB691FF, 0x9176E8], [0xFFD1BD, 0xF58DAF]])
        case "night": return ([0x171A49, 0x311044], [[0x8D8AFF, 0x6974F3], [0xFF83CF, 0xF351BE], [0xD8ABFF, 0x9A8FFF]])
        case "lagoon": return ([0xF4F1EF, 0xD8E4E9], [[0x9D8AE8, 0x7872CB], [0xED9B8D, 0xB98BBA], [0xC5B2EE, 0x9AA6D9]])
        case "paper": return ([0xFFF0BC, 0xF4D993], [[0x3BAE9D, 0x148E87], [0xFFA331, 0xF47852], [0x6C80F4, 0x4756CF]])
        case "prism": return ([0x291356, 0x211B4C], [[0xA163FF, 0x663DE3], [0xFFB64C, 0xF04C9A], [0xFA62C0, 0xAF40E5]])
        default: return ([0xF5F0FF, 0xEAE3FC], [[0x7C85D8, 0x626DC7], [0xA3A0EC, 0x888AE0], [0xD0B4F4, 0xBA9DE9]])
        }
    }

    static func gradient(_ ctx: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let values = colors.map { color($0) }
        let gradient = CGGradient(colorsSpace: space, colors: values as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Broad, low-contrast light keeps the surface satin rather than mirror-like.
    static func softLight(_ ctx: CGContext, color hex: UInt32, opacity: CGFloat,
                          center: CGPoint, radius: CGFloat) {
        let colors = [color(hex, alpha: opacity), color(hex, alpha: 0)]
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: colors as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(light, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    /// A shared light direction, with the finish tuned to each material.
    static func tileLighting(_ ctx: CGContext, tile: CGPath, variant: String) {
        let dark = variant == "night" || variant == "prism"
        let strength: CGFloat = dark ? 0.22 : (variant == "paper" ? 0.45 : 1)
        softLight(ctx, color: 0xFFFFFF, opacity: 0.42 * strength,
                  center: CGPoint(x: 240, y: 140), radius: 740)
        if variant == "slate" {
            softLight(ctx, color: 0xB99BE8, opacity: 0.19,
                      center: CGPoint(x: 800, y: 840), radius: 740)
        }
        // An inset bevel catches light only near the top-left. No uniform white frame.
        ctx.saveGState()
        ctx.addPath(tile); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
        softLight(ctx, color: 0xFFFFFF, opacity: 0.16 * strength,
                  center: CGPoint(x: 290, y: 120), radius: 560)
        softLight(ctx, color: 0x6E5C9F, opacity: 0.13 * strength,
                  center: CGPoint(x: 820, y: 880), radius: 570)
        ctx.restoreGState()
    }

    static func render(_ variant: String, pixels: Int) -> CGImage? {
        guard pixels > 0, pixels <= 4096,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        let palette = palette(variant)
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x343051, alpha: 0.18))
        ctx.addPath(tile); ctx.setFillColor(color(palette.tile[1])); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile); ctx.clip()
        gradient(ctx, palette.tile, from: CGPoint(x: 250, y: 100), to: CGPoint(x: 800, y: 924))
        tileLighting(ctx, tile: tile, variant: variant)
        ctx.saveGState()
        ctx.translateBy(x: 208, y: 274)
        ctx.scaleBy(x: 0.95, y: 0.95)
        let paths = ribbons.map(path)
        if variant == "paper" || variant == "sunrise" {
            // A single sticker silhouette, without white seams between the folds.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -9), blur: 12, color: color(0x805E85, alpha: 0.22))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setLineJoin(.round); ctx.setLineWidth(22)
            ctx.setFillColor(color(0xFFFAF6)); ctx.setStrokeColor(color(0xFFFAF6))
            for p in paths { ctx.addPath(p); ctx.drawPath(using: .fillStroke) }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for (index, p) in paths.enumerated() {
            ctx.saveGState()
            if variant == "slate" {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 9,
                              color: color(0x6954A0, alpha: 0.12))
                ctx.setFillColor(color(palette.ribbons[index][1]))
                ctx.addPath(p); ctx.fillPath()
                ctx.restoreGState()
            }
            if variant == "night" {
                ctx.setLineJoin(.round)
                ctx.setShadow(offset: .zero, blur: 19, color: color(palette.ribbons[index][0]))
                ctx.setLineWidth(9); ctx.setStrokeColor(color(palette.ribbons[index][1]))
                ctx.setFillColor(color(0x251B50)); ctx.addPath(p); ctx.drawPath(using: .fillStroke)
                ctx.setShadow(offset: .zero, blur: 5, color: color(palette.ribbons[index][0]))
                ctx.setLineWidth(3); ctx.setStrokeColor(color(0xFFF0FF)); ctx.addPath(p); ctx.strokePath()
            } else {
                ctx.addPath(p); ctx.clip()
                gradient(ctx, palette.ribbons[index], from: CGPoint(x: 180, y: 40), to: CGPoint(x: 550, y: 470))
                if variant == "slate" {
                    // Soft fold shading, without specular white strokes on the ribbon.
                    softLight(ctx, color: 0xF3E7FF, opacity: 0.12,
                              center: CGPoint(x: 220, y: 70), radius: 370)
                    softLight(ctx, color: 0x6556B1, opacity: index == 1 ? 0.19 : 0.10,
                              center: CGPoint(x: 570, y: 440), radius: 350)
                }
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        if variant == "lagoon" {
            // Translucent vertical ribs preserve the silhouette at small Dock sizes.
            for x in stride(from: 100, to: 924, by: 12) {
                ctx.setFillColor(color(0xFFFFFF, alpha: 0.34))
                ctx.fill(CGRect(x: x, y: 100, width: 4, height: 824))
                ctx.setFillColor(color(0x615D8E, alpha: 0.12))
                ctx.fill(CGRect(x: x + 5, y: 100, width: 2, height: 824))
            }
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func svg() -> String {
        let colors = palette("slate").ribbons
        let defs = colors.enumerated().map { index, pair in
            "<linearGradient id=\"r\(index)\" gradientUnits=\"userSpaceOnUse\" x1=\"180\" y1=\"40\" x2=\"550\" y2=\"470\"><stop stop-color=\"#\(String(format: "%06X", pair[0]))\"/><stop offset=\"1\" stop-color=\"#\(String(format: "%06X", pair[1]))\"/></linearGradient>"
        }.joined()
        let paths = ribbons.enumerated().map { "<path d=\"\($0.element)\" fill=\"url(#r\($0.offset))\"/>" }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-10 -10 660 490\" role=\"img\" aria-label=\"Open Arc\"><defs>\(defs)</defs>\(paths)</svg>\n"
    }
}
