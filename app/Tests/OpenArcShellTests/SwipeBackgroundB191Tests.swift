import XCTest
import AppKit
import QuartzCore
import Combine
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Issue #15, plans B191 / B195 (`06 §39`): while the sidebar pages slide between Spaces, the window
/// background blends from the current Space's colors to the target's with them, reaching the
/// target's when the pages are half way (user, 2026-11-09), and settles on the pages' spring after
/// the fingers lift. The blend reaches the background's layer without SwiftUI updates.
@MainActor
final class SwipeBackgroundB191Tests: XCTestCase {
    /// A swipe whose settle frames the test runs by hand (`ticks`).
    private final class Frames {
        var ticks: [@MainActor (Double) -> Bool] = []
        /// Runs the newest settle at `elapsed` seconds; returns whether it goes on.
        @MainActor @discardableResult func run(_ elapsed: Double) -> Bool { ticks.last?(elapsed) ?? false }
    }

    private func makeSwipe(_ frames: Frames = Frames()) -> SpaceSwipeState {
        let swipe = SpaceSwipeState()
        swipe.pageWidth = 276
        swipe.frameDriver = { frames.ticks.append($0) }
        return swipe
    }

    // MARK: Curve

    /// Half way across the background shows the target's colors; it starts and arrives smoothly.
    func testProgressReachesTheTargetAtTheMidline() {
        XCTAssertEqual(SpaceBlend.progress(travel: 0, start: 0, width: 276), 0)
        XCTAssertEqual(SpaceBlend.progress(travel: 69, start: 0, width: 276), 0.5, accuracy: 0.001)
        XCTAssertEqual(SpaceBlend.progress(travel: 138, start: 0, width: 276), 1, "the target's colors at the midline")
        XCTAssertEqual(SpaceBlend.progress(travel: 276, start: 0, width: 276), 1)
        XCTAssertLessThan(SpaceBlend.progress(travel: 10, start: 0, width: 276), 10.0 / 138.0, "eases in")
        // A slide that began part of the way across blends over the rest of the way.
        XCTAssertEqual(SpaceBlend.progress(travel: 176, start: 176, width: 276), 0)
        XCTAssertEqual(SpaceBlend.progress(travel: 226, start: 176, width: 276), 1)
        XCTAssertEqual(SpaceBlend.progress(travel: 276, start: 276, width: 276), 1, "already in place")
    }

    /// The settle follows the Space-switch spring ([07 §11] observed: critically damped, 0.2 s).
    func testSpringFractionMatchesTheSpaceSwitchSpring() {
        XCTAssertEqual(SpaceBlend.springFraction(elapsed: 0), 0)
        let omega = 2 * Double.pi / 0.2
        let t = 0.05
        XCTAssertEqual(SpaceBlend.springFraction(elapsed: t), 1 - (1 + omega * t) * exp(-omega * t), accuracy: 0.0001)
        XCTAssertLessThan(SpaceBlend.springFraction(elapsed: 0.1), SpaceBlend.springFraction(elapsed: 0.15))
        XCTAssertEqual(SpaceBlend.springFraction(elapsed: 0.5), 1, "at rest")
        XCTAssertEqual(SpaceBlend.springFraction(elapsed: .infinity), 1)
    }

    // MARK: Swipe

    func testSwipeBlendsByTravel() {
        let previous = UUID(), next = UUID()
        let swipe = makeSwipe()
        swipe.begin(previous: previous, next: next)
        XCTAssertEqual(swipe.blendProgress, 0)
        XCTAssertNil(swipe.blendTargetSpaceID)

        swipe.move(-69)
        XCTAssertEqual(swipe.blendTargetSpaceID, next, "content to the left reveals the next Space")
        XCTAssertEqual(swipe.blendProgress, 0.5, accuracy: 0.001)
        swipe.move(-138)
        XCTAssertEqual(swipe.blendProgress, 1, accuracy: 0.001, "the target's colors at the midline")
        swipe.move(-400)
        XCTAssertEqual(swipe.blendTravel, 276, "capped at a page")

        swipe.move(60)
        XCTAssertEqual(swipe.blendTargetSpaceID, previous, "the other way blends to the previous Space")
        XCTAssertEqual(swipe.blendTravel, 60)
    }

    /// No neighbor that way: nothing to blend to, and letting go has nothing to settle.
    func testNoTargetAtTheEnd() {
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.begin(previous: nil, next: UUID())
        swipe.move(80)
        XCTAssertNil(swipe.blendTargetSpaceID)
        XCTAssertEqual(swipe.blendProgress, 0)
        swipe.end(target: nil)
        XCTAssertTrue(frames.ticks.isEmpty)
    }

    /// A committed swipe settles on to the target with the pages, frame by frame; then the
    /// background shows the (now selected) target as it is.
    func testCommitSettlesToTheTarget() {
        let next = UUID()
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.begin(previous: nil, next: next)
        swipe.move(-40)
        let before = swipe.blendProgress
        swipe.end(target: next)
        XCTAssertEqual(swipe.settleTravel, 276)
        XCTAssertTrue(frames.run(0.03))
        XCTAssertGreaterThan(swipe.blendTravel, 40)
        XCTAssertGreaterThan(swipe.blendProgress, before)
        XCTAssertEqual(swipe.blendTargetSpaceID, next)
        XCTAssertFalse(frames.run(1))
        XCTAssertNil(swipe.blendTargetSpaceID, "settled")
        XCTAssertNil(swipe.settleTravel)

        // The selection change that follows does not restart the blend.
        swipe.begin(previous: nil, next: next)
        swipe.move(-200)
        swipe.end(target: next)
        let generation = swipe.blendGeneration, count = frames.ticks.count
        swipe.slide(to: next, travel: 76)
        XCTAssertEqual(swipe.blendGeneration, generation)
        XCTAssertEqual(frames.ticks.count, count)
    }

    /// Released short, the blend goes back to the current Space's colors with the pages.
    func testSpringBackSettlesToTheStart() {
        let next = UUID()
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.begin(previous: nil, next: next)
        swipe.move(-60)
        swipe.end(target: nil)
        XCTAssertEqual(swipe.settleTravel, 0)
        frames.run(0.03)
        XCTAssertLessThan(swipe.blendTravel, 60)
        XCTAssertEqual(swipe.blendTargetSpaceID, next, "fades back instead of vanishing")
        frames.run(1)
        XCTAssertNil(swipe.blendTargetSpaceID)
    }

    /// A new swipe during a settle: the old settle's frames stop and do not touch the new blend.
    func testOvertakenSettleStops() {
        let current = UUID(), next = UUID()
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.begin(previous: nil, next: next)
        swipe.move(-200)
        swipe.end(target: next)
        let old = frames.ticks[0]
        swipe.begin(previous: current, next: nil)
        swipe.move(100)
        XCTAssertFalse(old(0.05))
        XCTAssertFalse(old(1))
        XCTAssertEqual(swipe.blendTargetSpaceID, current)
        XCTAssertEqual(swipe.blendTravel, 100)
    }

    /// The blend changes nothing SwiftUI observes: only `isActive` is published, at the start and
    /// the end (the swipe stuttered when every move updated views, B195).
    func testMovesPublishNothing() {
        let swipe = makeSwipe()
        swipe.begin(previous: nil, next: UUID())
        var published = 0, blendChanges = 0
        let a = swipe.objectWillChange.sink { _ in published += 1 }
        let b = swipe.blendChanges.sink { blendChanges += 1 }
        for step in 1...20 { swipe.move(CGFloat(-10 * step)) }
        XCTAssertEqual(published, 0)
        XCTAssertEqual(blendChanges, 20)
        _ = (a, b)
    }

    // MARK: Dock and shortcut switches

    /// A switch that is not a swipe blends with the sliding page too, from the colors on screen.
    func testSlideBlendsOverTheSwitch() {
        let target = UUID()
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.slide(to: target, travel: 0)
        XCTAssertEqual(swipe.blendTargetSpaceID, target)
        XCTAssertEqual(swipe.blendProgress, 0)
        frames.run(0.03)
        XCTAssertGreaterThan(swipe.blendProgress, 0)
        frames.run(1)
        XCTAssertNil(swipe.blendTargetSpaceID)

        // Overtaking a slide: the incoming page is part of the way across already.
        swipe.slide(to: target, travel: 200)
        XCTAssertEqual(swipe.blendTravel, 200)
        XCTAssertEqual(swipe.blendProgress, 0, "starts from the colors on screen")
    }

    /// B208, 06 §39 observed in Arc: a Dock or shortcut switch moves the color with the page,
    /// linearly (half way at half the travel); a swipe keeps the midline rule.
    func testDockSwitchFollowsThePageLinearly() {
        let frames = Frames()
        let swipe = makeSwipe(frames)
        swipe.slide(to: UUID(), travel: 0)
        XCTAssertTrue(swipe.blendFollowsPage)
        XCTAssertEqual(swipe.blendProgress(atTravel: 138), 0.5, accuracy: 0.001)
        XCTAssertEqual(swipe.blendProgress(atTravel: 276), 1, accuracy: 0.001)
        XCTAssertEqual(swipe.settleRun?.to, 276)
        frames.run(1)
        XCTAssertNil(swipe.settleRun)
        swipe.begin(previous: nil, next: UUID())
        XCTAssertFalse(swipe.blendFollowsPage)
        swipe.move(-138)
        XCTAssertEqual(swipe.blendProgress, 1, accuracy: 0.001, "a swipe reaches the target by the midline")
    }

    /// B208: the settle runs as a layer animation, so a busy main thread cannot hold the color back.
    func testSettleRunsOnTheLayer() throws {
        var f = SidebarFixture()
        let theme = SidebarFixture.id(900)
        f.ws = TreeOps.createTheme(f.ws, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x2E6BE6)]), now: f.now)
        f.ws = try TreeOps.setSpaceTheme(f.ws, id: f.work, themeID: theme, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        let frames = Frames()
        vm.spaceSwipe.frameDriver = { frames.ticks.append($0) }
        vm.spaceSwipe.pageWidth = 276
        let view = SpaceBlendPaintView()
        view.update(sidebar: vm, idle: WindowPaint(palette: vm.palette(forSpace: f.home), surface: .opaque), surface: .opaque)
        vm.spaceSwipe.slide(to: f.work, travel: 0)
        let group = try XCTUnwrap(view.settleAnimationForTesting as? CAAnimationGroup)
        XCTAssertEqual(group.duration, SpaceBlend.springSettleTime, accuracy: 0.001)
        XCTAssertEqual(group.animations?.count, 4)
        frames.run(1)
        XCTAssertNil(view.settleAnimationForTesting, "removed once settled")
    }

    // MARK: Paint

    /// Colors mix premultiplied: a translucent paint does not show the other through it.
    func testMixIsPremultiplied() {
        let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.6)
        let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.6)
        let half = WindowPaint.mix(red, blue, 0.5)
        XCTAssertEqual(half.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.blue, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.alpha, 0.6, accuracy: 0.0001)
        let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        XCTAssertEqual(WindowPaint.mix(clear, red, 0.5).red, 1, accuracy: 0.0001, "a clear color takes the other's hue")
    }

    func testBlendOfPaints() {
        let a = WindowPaint(colors: [RGBAColor(red: 1, green: 0, blue: 0)], locations: [0], axis: .vertical)
        let b = WindowPaint(colors: [RGBAColor(red: 0, green: 0, blue: 1), RGBAColor(red: 0, green: 1, blue: 0)],
                            locations: [0, 1], axis: .diagonal)
        XCTAssertEqual(WindowPaint.blend(a, b, 0), a)
        XCTAssertEqual(WindowPaint.blend(a, b, 1), b)
        let half = WindowPaint.blend(a, b, 0.5)
        XCTAssertEqual(half.locations, [0, 1])
        XCTAssertEqual(half.axis, .diagonal, "a one-color paint takes the gradient's axis")
        XCTAssertEqual(half.colors[0].red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.colors[1].green, 0.5, accuracy: 0.0001)
        let solid = WindowPaint.blend(a, a, 0.5)
        XCTAssertEqual(solid.colors.count, 1)
    }

    /// The background's layer follows the blend from the colors it showed when the blend began.
    func testPaintViewFollowsTheBlend() throws {
        var f = SidebarFixture()
        let theme = SidebarFixture.id(900)
        f.ws = TreeOps.createTheme(f.ws, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x2E6BE6)]), now: f.now)
        f.ws = try TreeOps.setSpaceTheme(f.ws, id: f.work, themeID: theme, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        let frames = Frames()
        vm.spaceSwipe.frameDriver = { frames.ticks.append($0) }
        vm.spaceSwipe.pageWidth = 276
        let surface = WindowSurface.opaque
        let home = WindowPaint(palette: vm.palette(forSpace: f.home), surface: surface)
        let work = WindowPaint(palette: vm.palette(forSpace: f.work), surface: surface)
        XCTAssertNotEqual(home, work, "the fixture's Spaces have different colors")
        let view = SpaceBlendPaintView()
        view.update(sidebar: vm, idle: home, surface: surface)
        XCTAssertEqual(view.shown, home)

        XCTAssertTrue(vm.spaceSwipeBegan())
        vm.spaceSwipeMoved(offset: -69)
        XCTAssertEqual(view.shown, .blend(home, work, 0.5))
        vm.spaceSwipeMoved(offset: -150)
        XCTAssertEqual(view.shown, work, "the target's colors past the midline")
        let layerColors = try XCTUnwrap(view.gradientLayerForTesting.colors as? [CGColor])
        XCTAssertEqual(layerColors.first?.components?.first ?? -1, work.colors[0].red, accuracy: 0.001)
    }

    /// The gradient axis is given in SwiftUI's y-down unit space; the layer's is y-up.
    func testLayerPointFlipsY() {
        XCTAssertEqual(SpaceBlendPaintView.layerPoint(x: 0, y: 0), CGPoint(x: 0, y: 1))
        XCTAssertEqual(SpaceBlendPaintView.layerPoint(x: 1, y: 1), CGPoint(x: 1, y: 0))
    }
}
