import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign
@testable import OpenArcShell

/// B40: every animated surface uses its `OpenArcDesign.Motion` token.
/// Spec: docs/arc-spec/07-design-system.md §11 动效(E7).
@MainActor
final class ShellMotionTests: XCTestCase {
    /// Each surface's SwiftUI animation is its token's curve. [07 §11]
    func testSurfacesUseTheirTokens() {
        XCTAssertEqual(ShellMotion.spaceSwitch, .spring(response: 0.2, dampingFraction: 1.0))
        XCTAssertEqual(ShellMotion.spaceCreateFade, .easeInOut(duration: 0.3))
        XCTAssertEqual(ShellMotion.sidebarToggle, .timingCurve(0.03, 0.62, 0.54, 0.95, duration: 0.067))
        XCTAssertEqual(ShellMotion.sidebarPeekSlide, .easeOut(duration: 0.15))
        XCTAssertEqual(ShellMotion.favoriteMakeRoom, .easeInOut(duration: 0.15))
        XCTAssertEqual(ShellMotion.themeBubbleOpen, .spring(response: 0.31, dampingFraction: 0.81))
        XCTAssertEqual(ShellMotion.themeBubbleClose, .spring(response: 0.35, dampingFraction: 0.85))
        XCTAssertEqual(ShellMotion.littleArcOpen, .spring(response: 0.24, dampingFraction: 0.45))
        XCTAssertEqual(ShellMotion.littleArcClose, .timingCurve(0.27, 1.0, 0.40, 0.98, duration: 0.2))
        XCTAssertEqual(ShellMotion.littleArcExpandToMain, .timingCurve(0.33, 0.71, 0.19, 1.0, duration: 0.19))
        XCTAssertNil(MotionCurve.instant.swiftUI, "instant = no animation")
    }

    /// The window fade of a closing Little Arc follows how it closed. [07 §11] observed.
    func testLittleArcCloseMotionFollowsCloseStyle() {
        XCTAssertEqual(LittleArcWindowView.closeMotion(.dismiss), Motion.littleArcClose)
        XCTAssertEqual(LittleArcWindowView.closeMotion(.adopt), Motion.littleArcExpandToMain)
        let fn = try! XCTUnwrap(Motion.littleArcClose.curve.mediaTimingFunction)
        var p = [Float](repeating: 0, count: 2)
        fn.getControlPoint(at: 1, values: &p)
        XCTAssertEqual(p, [0.27, 1.0])
        fn.getControlPoint(at: 2, values: &p)
        XCTAssertEqual(p, [0.40, 0.98])
    }

    /// The Space page moves toward the dock side of the new Space by one sidebar width (276 pt),
    /// and the outgoing page leaves the other way. [07 §11] observed.
    func testSpacePagerDirection() {
        let a = UUID(), b = UUID(), c = UUID()
        let order = [a, b, c]
        XCTAssertEqual(SpaceSwitchDirection.between(a, c, order: order), .forward)
        XCTAssertEqual(SpaceSwitchDirection.between(c, b, order: order), .backward)
        XCTAssertEqual(SpaceSwitchDirection.between(a, UUID(), order: order), .forward)

        let pager = SpacePagerState(spaceID: a)
        XCTAssertEqual(pager.pageWidth, 276)
        pager.show(c, order: order)
        XCTAssertEqual(pager.direction, .forward)
        XCTAssertEqual(pager.offset(for: .insertion), 276, "the next Space comes in from the right")
        XCTAssertEqual(pager.offset(for: .removal), -276)
        pager.show(a, order: order)
        XCTAssertEqual(pager.direction, .backward)
        XCTAssertEqual(pager.offset(for: .insertion), -276)
        XCTAssertEqual(pager.offset(for: .removal), 276)
    }

    /// The sidebar view model keeps its pager in step with the selected Space.
    func testSidebarSwitchUpdatesPager() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectSpace(f.home)
        vm.selectSpace(f.work)
        XCTAssertEqual(vm.spacePager.spaceID, f.work)
        XCTAssertEqual(vm.spacePager.direction, .forward)
        vm.stepSpace(by: -1)
        XCTAssertEqual(vm.spacePager.spaceID, f.home)
        XCTAssertEqual(vm.spacePager.direction, .backward)
    }

    /// Escape fades the Little Arc window out before it closes. [07 §11] observed: alpha 1 → 0
    /// over ≈ 0.2 s, then the window goes away.
    func testLittleArcFadesOutOnClose() async throws {
        let f = SidebarFixture()
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        let model = LittleArcModel(shell: controller.littleArcHost())
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: model.windowSize),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LittleArcWindowView(model: model))
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(window.alphaValue, 1, "no fade-in on open")
        XCTAssertEqual(window.animationBehavior, .none, "no system open/close animation")

        XCTAssertEqual(model.commandBar.handle(.escape), .dismiss)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(window.isVisible, "still fading")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(window.isVisible)
    }

    /// Arc shows no frame animation for the command bar, row insert/remove, folder disclosure,
    /// split view or the Library ([07 §11] observed one-frame changes). Every animation in the
    /// shell goes through `ShellMotion` (or the own-design onboarding), so a new local curve on
    /// one of those surfaces shows up here.
    func testNoLocalAnimationCurves() throws {
        let shellDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenArcShell")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: shellDir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        // Onboarding is our own design (no Arc counterpart); the tab dialog is out of scope (B40).
        let allowed: Set<String> = ["ShellMotion.swift", "OnboardingView.swift", "TabDialogViews.swift"]
        let patterns = [".animation(.", "withAnimation(.", "Animation.spring", "Animation.ease", ".easeInOut(", ".easeOut(", ".spring("]
        var offenders: [String] = []
        for file in files where !allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() where patterns.contains(where: line.contains) {
                offenders.append("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "use a `ShellMotion` token ([07 §11])")
    }
}
