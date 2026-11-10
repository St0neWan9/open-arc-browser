import XCTest
import QuartzCore
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Plan B211: the hidden sidebar's floating panel blends its fill between Spaces with the sidebar
/// pages, like the window background behind a pinned sidebar.
@MainActor
final class SidebarPeekBlendB211Tests: XCTestCase {
    func testPeekPanelFillFollowsTheSwipe() throws {
        var f = SidebarFixture()
        let theme = SidebarFixture.id(900)
        f.ws = TreeOps.createTheme(f.ws, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x2E6BE6)]), now: f.now)
        f.ws = try TreeOps.setSpaceTheme(f.ws, id: f.work, themeID: theme, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        var ticks: [@MainActor (Double) -> Bool] = []
        vm.spaceSwipe.frameDriver = { ticks.append($0) }
        vm.spaceSwipe.pageWidth = 276

        let home = SpaceBlendFill.peekPanel.paint(for: vm.palette(forSpace: f.home))
        let work = SpaceBlendFill.peekPanel.paint(for: vm.palette(forSpace: f.work))
        XCTAssertEqual(home.colors, [SidebarPeekTokens.panelFill(for: vm.palette(forSpace: f.home))])
        XCTAssertNotEqual(home, work)

        let view = SpaceBlendPaintView()
        view.cornerRadius = SidebarPeekTokens.panelCornerRadius
        view.update(sidebar: vm, idle: home, fill: .peekPanel)
        XCTAssertEqual(view.shown, home)
        XCTAssertTrue(view.gradientLayerForTesting.masksToBounds, "the paint is clipped to the panel's corners")

        XCTAssertTrue(vm.spaceSwipeBegan())
        vm.spaceSwipeMoved(offset: -69)
        XCTAssertEqual(view.shown, .blend(home, work, 0.5), "the panel fill is between the two Spaces'")
        vm.spaceSwipeMoved(offset: -150)
        XCTAssertEqual(view.shown, work, "the target's panel fill past the midline")
    }
}
