import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// B41: every web content surface carries the E14 edge shadow. [07 §7.1]
@MainActor
final class WebPanelShadowTests: XCTestCase {
    /// [07 §7.1] observed: the main panel, split panes, the Little Arc page and the Library's
    /// content panel all show the same edge shadow. Each view applies `webPanelEdgeShadow` with
    /// the palette's appearance, and none keeps a hand-written web panel shadow.
    func testEverySurfaceAppliesTheEdgeShadow() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenArcShell")
        let surfaces = [
            "Views.swift",                     // main web panel
            "SplitView/SplitWebArea.swift",    // split panes
            "LittleArc/LittleArcWindow.swift", // Little Arc expanded page
            "Library/LibraryView.swift",       // Library content panel
        ]
        for file in surfaces {
            let source = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains(".webPanelEdgeShadow(palette.appearance)"), "\(file) applies the E14 shadow")
            XCTAssertFalse(source.contains("webPanelShadowOpacity"), "\(file) has no old hand-written shadow")
        }
    }

    /// The modifier darkens the window just outside the panel, more below than above (y offset),
    /// and the dark-Space shadow is at least as strong. [07 §7.1]
    func testEdgeShadowRendersBelowAndBesideThePanel() throws {
        func render(_ appearance: ResolvedAppearance) throws -> (below: Double, above: Double, beside: Double) {
            let view = ZStack {
                Color(white: 0.7)
                RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 60, height: 60)
                    .webPanelEdgeShadow(appearance)
            }
            .frame(width: 100, height: 100)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            func darkening(_ x: Int, _ y: Int) -> Double {
                let bg = rep.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!.brightnessComponent
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.brightnessComponent
                return 1 - c / bg
            }
            // Panel spans 20...79 in both axes.
            return (darkening(50, 81), darkening(50, 18), darkening(18, 50))
        }
        let light = try render(.light)
        XCTAssertGreaterThan(light.below, 0.05)
        XCTAssertGreaterThan(light.beside, 0.03)
        XCTAssertGreaterThan(light.below, light.above, "y + 1 offset")
        let dark = try render(.dark)
        XCTAssertGreaterThanOrEqual(dark.below + 0.005, light.below)
    }
}
