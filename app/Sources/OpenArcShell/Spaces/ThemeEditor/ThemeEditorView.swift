import SwiftUI
import OpenArcModel
import OpenArcDesign

/// The theme bubble. [06 §2] observed: three icon segments (automatic / light / dark), a dot-grid
/// color pad with the hint "Tap to pick a color for this space" and − / + buttons, one row of nine
/// round swatches with left and right arrows that page through named groups, and at the bottom a
/// wavy slider (the theme color's intensity) and a ring knob (grain); B159 observed from Arc's
/// stored values (intensity 0.8 puts the thumb at 80 % of the track, grain 0 puts the knob marker
/// at the top).
/// [07 §6] observed: visible bubble ≈ 356 × 508, radius 20, padding 8, a 340 × 340 dot pad,
/// 24 pt preset swatches at a 29.5 pitch, 32 pt segment buttons at a 40 pitch. B158 (2x capture of
/// Arc 1.170, 2026-11-03, observed): the segments and the − / + sit inside the pad, a flat
/// near-white fill tinted by the theme, a dense dot grid, a large ringed color point, a thick wave
/// on a gray track with a tall pill thumb, a thin ring knob with 20 dots and a pill marker
/// (`ThemeEditorMetrics`).
/// With the dark segment (or automatic on a dark system) the bubble goes dark: the theme color
/// darkened, light icons, a pale block on the selected segment, a dimmed dot grid.
/// [04 §dark mode (E7)] observed; values from `ThemePalette` (approximate).
///
/// The view edits `theme` through the binding; the owner applies each change right away, so the
/// Space's window updates while the bubble is open.
struct ThemeEditorView: View {
    @Binding var theme: SpaceThemeDraft
    /// The system setting, for a draft set to Automatic.
    let systemAppearance: ResolvedAppearance

    @State private var presetPage: Int
    /// Point being dragged on the pad; nil between gestures.
    @State private var draggedPoint: Int?

    private typealias M = ThemeEditorMetrics

    /// Fills and clips its own rounded background. Off inside a floating bubble, whose chrome
    /// (`FloatingBubbleChrome`) draws the tint, rim and arrow instead (B42).
    var drawsBackground = true

    init(theme: Binding<SpaceThemeDraft>, systemAppearance: ResolvedAppearance = .light, drawsBackground: Bool = true) {
        _theme = theme
        self.systemAppearance = systemAppearance
        self.drawsBackground = drawsBackground
        _presetPage = State(initialValue: ThemePresets.pageContaining(theme.wrappedValue.colors.first))
    }

    /// The bubble follows the theme being edited, so switching the segment restyles it at once.
    private var palette: ThemePalette { Self.palette(for: theme, systemAppearance: systemAppearance) }

    /// The palette the bubble shows for `theme`; its chrome uses the same one.
    static func palette(for theme: SpaceThemeDraft, systemAppearance: ResolvedAppearance) -> ThemePalette {
        ThemeDerivation.palette(forStyle: theme.style, systemAppearance: systemAppearance)
    }

    /// Floating-bubble chrome for this bubble ([07 §6] size and radius, [07 §12] tint). A flat
    /// tint: the B158 capture shows one fill from top to bottom (#FDF9F6 on a peach Space), not
    /// the E8 glow ([07 §8.4] finding 3), observed.
    static func bubbleStyle(for theme: SpaceThemeDraft, systemAppearance: ResolvedAppearance) -> FloatingBubbleStyle {
        let palette = palette(for: theme, systemAppearance: systemAppearance)
        return FloatingBubbleStyle(width: ThemeEditorMetrics.size.width, height: ThemeEditorMetrics.size.height,
                                   cornerRadius: ThemeEditorMetrics.cornerRadius,
                                   tint: palette.floatingPanelBackground, isDark: palette.isDark, usesGradient: false)
    }

    /// Ink for icons, labels and tracks: black in light, white in dark.
    private var ink: Color { palette.floatingPanelInk.swiftUI }

    var body: some View {
        VStack(spacing: 0) {
            colorPad
            presetRow
                .frame(height: M.swatchSize)
                .padding(.top, M.presetRowTop - M.padding - M.padSize)
            bottomControls
                .padding(.top, M.controlsTop - M.presetRowTop - M.swatchSize)
            Spacer(minLength: 0)
        }
        .padding(M.padding)
        .frame(width: M.size.width, height: M.size.height)
        .background(drawsBackground ? AnyShapeStyle(palette.floatingPanelBackground.swiftUI) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.themeEditor")
    }

    // MARK: Appearance

    /// Inside the pad, near its top, centered. B158 observed.
    private var appearanceSegments: some View {
        HStack(spacing: M.segmentPitch - M.segmentSize) {
            segment(.automatic, symbol: "sparkles", label: "Automatic")
            segment(.light, symbol: "sun.max.fill", label: "Light")
            segment(.dark, symbol: "moon.stars.fill", label: "Dark")
        }
    }

    private func segment(_ appearance: ThemeAppearance, symbol: String, label: String) -> some View {
        let selected = theme.appearance == appearance
        return Button { theme.appearance = appearance } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ink.opacity(M.iconInk))
                .frame(width: M.segmentSize, height: M.segmentSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? (palette.isDark ? palette.floatingPanelSelection.swiftUI : ink.opacity(M.selectedSegmentInk)) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("openarc.themeEditor.appearance.\(appearance.rawValue)")
    }

    // MARK: Color pad

    private var colorPad: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: M.padCornerRadius, style: .continuous).fill(ink.opacity(M.padInk))
                DotGrid(ink: ink, opacity: palette.isDark ? 0.14 : M.dotInk)
                if theme.colors.isEmpty {
                    Text("Tap to pick a color for this space")
                        .font(Typography.panelRowTitle.font)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ink.opacity(0.4))
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
                ForEach(Array(theme.colors.enumerated()), id: \.offset) { _, color in
                    let p = ThemePad.position(of: color)
                    Circle()
                        .fill(color.swiftUI)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: M.pointRing))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                        .frame(width: M.pointSize, height: M.pointSize)
                        .position(Self.padPoint(p, in: size))
                        .allowsHitTesting(false)
                }
                appearanceSegments
                    .position(x: size.width / 2, y: M.segmentCenterY)
                padButtons
                    .position(x: size.width / 2, y: size.height - M.padButtonsBottom)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let position = ThemePad.clamped(Self.padUnit(value.location, in: size))
                        if let index = draggedPoint {
                            theme.movePoint(index, to: position)
                        } else {
                            draggedPoint = theme.beginPadInteraction(at: position)
                        }
                    }
                    .onEnded { _ in draggedPoint = nil }
            )
        }
        .frame(width: M.padSize, height: M.padSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tap to pick a color for this space")
        .accessibilityIdentifier("openarc.themeEditor.pad")
    }

    /// Unit pad positions map onto the pad inset by half a point's size, so a 44 pt point at an
    /// edge stays inside the pad (inferred; Arc's edge behavior was not captured). B158.
    static func padPoint(_ unit: CGPoint, in size: CGSize) -> CGPoint {
        let inset = M.pointSize / 2
        return CGPoint(x: inset + unit.x * max(size.width - 2 * inset, 1), y: inset + unit.y * max(size.height - 2 * inset, 1))
    }

    static func padUnit(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let inset = M.pointSize / 2
        return CGPoint(x: (point.x - inset) / max(size.width - 2 * inset, 1), y: (point.y - inset) / max(size.height - 2 * inset, 1))
    }

    /// − and + centered near the bottom of the pad, plain gray glyphs; both dimmed when no point is
    /// placed. [06 §2] observed; place and look B158 observed.
    private var padButtons: some View {
        HStack(spacing: M.padButtonPitch - M.padButtonSize) {
            padButton("minus", label: "Remove color", enabled: theme.canRemovePoint) { theme.removeLastPoint() }
            padButton("plus", label: "Add color", enabled: theme.canAddPoint) { theme.addPoint() }
        }
    }

    private func padButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink.opacity(enabled ? M.glyphInk : M.disabledGlyphInk))
                .frame(width: M.padButtonSize, height: M.padButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Presets

    private var presetRow: some View {
        let group = ThemePresets.groups[presetPage]
        // [07 §8.5] observed: one row of nine swatches between two arrows, no group name under it.
        return HStack(spacing: M.swatchPitch - M.swatchSize) {
            pageArrow("chevron.left", step: -1)
                .padding(.trailing, M.arrowGap - (M.swatchPitch - M.swatchSize))
            ForEach(Array(group.swatches.enumerated()), id: \.offset) { _, swatch in
                Button { theme.applyPreset(swatch) } label: {
                    swatchFill(swatch)
                        .frame(width: M.swatchSize, height: M.swatchSize)
                        .overlay(Circle().strokeBorder(Self.swatchRim(swatch).swiftUI, lineWidth: 1))
                        .overlay(Circle().strokeBorder(ink.opacity(theme.colors == swatch ? 0.8 : 0), lineWidth: 1.5).padding(-2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.name) color")
            }
            pageArrow("chevron.right", step: 1)
                .padding(.leading, M.arrowGap - (M.swatchPitch - M.swatchSize))
        }
        .frame(maxWidth: .infinity)
    }

    /// A 1 pt rim of the swatch's own color, darkened (#ECB1C6 → #D9A2B6). B158 observed.
    static func swatchRim(_ swatch: [RGBAColor]) -> RGBAColor {
        ThemeDerivation.shade(swatch.first ?? RGBAColor(hex: 0xFFFFFF), by: ThemeEditorMetrics.swatchRimShade)
    }

    /// A plain swatch is one color; a gradient swatch runs from its first color at the top left
    /// to its last at the bottom right. The three colors of a page-2 swatch were read at the center
    /// and 4.8 pt up-left / down-right of it ([07 §8.5] observed), so they sit at those points of
    /// the gradient (0.3 / 0.5 / 0.7) and the ends hold the outer colors.
    @ViewBuilder
    private func swatchFill(_ swatch: [RGBAColor]) -> some View {
        if swatch.count > 1 {
            // Core Graphics in sRGB, so each stop lands on its exact color (SwiftUI's gradient
            // drifted by up to 26/255 at the stops on the display).
            Canvas { context, size in
                let step = M.gradientSwatchSampleSpread / Double(swatch.count - 1)
                let start = 0.5 - M.gradientSwatchSampleSpread / 2
                let locations = swatch.indices.map { CGFloat(start + Double($0) * step) }
                let colors = swatch.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } as CFArray
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
                context.withCGContext { cg in
                    cg.addEllipse(in: CGRect(origin: .zero, size: size))
                    cg.clip()
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
        } else {
            Circle().fill((swatch.first ?? RGBAColor(hex: 0xFFFFFF)).swiftUI)
        }
    }

    private func pageArrow(_ symbol: String, step: Int) -> some View {
        let target = ThemePresets.page(after: presetPage, step: step)
        return Button { presetPage = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.opacity(target == presetPage ? M.disabledGlyphInk : M.glyphInk))
                .frame(width: M.arrowWidth, height: M.swatchSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == presetPage)
        .accessibilityLabel(step < 0 ? "Previous colors" : "Next colors")
    }

    // MARK: Bottom controls

    /// The wave slider from x 10 of the content, the knob 16 from its right edge. B158 observed.
    private var bottomControls: some View {
        HStack(spacing: 0) {
            WavySlider(value: $theme.intensity, ink: ink)
                .frame(width: M.sliderWidth)
                .padding(.leading, M.sliderLeading)
                .accessibilityLabel("Color intensity")
                .accessibilityIdentifier("openarc.themeEditor.intensity")
            Spacer(minLength: 0)
            RingKnob(value: $theme.grain, ink: ink)
                .padding(.trailing, M.knobTrailing)
                .accessibilityLabel("Texture")
                .accessibilityIdentifier("openarc.themeEditor.grain")
        }
        .frame(height: M.knobSize)
    }
}

/// Sizes of the bubble, in bubble points. [07 §6] observed (size, radius, padding, pad, swatches,
/// segments); the rest B158 observed in a 2x capture of Arc 1.170 (2026-11-03) unless noted.
enum ThemeEditorMetrics {
    static var size: CGSize { CGSize(width: Metrics.ThemePicker.size.width, height: Metrics.ThemePicker.size.height) }
    static var cornerRadius: CGFloat { CGFloat(Metrics.ThemePicker.cornerRadius) }
    static var padding: CGFloat { CGFloat(Metrics.ThemePicker.padding) }
    static var segmentSize: CGFloat { CGFloat(Metrics.ThemePicker.segmentButtonSize) }
    static var segmentPitch: CGFloat { CGFloat(Metrics.ThemePicker.segmentButtonPitch) }
    static var padSize: CGFloat { CGFloat(Metrics.ThemePicker.dotGridSize) }
    static let padCornerRadius: CGFloat = 8.5
    /// Segment row center, from the pad's top.
    static let segmentCenterY: CGFloat = 40.5
    /// Dot grid: 1.1 pt dots at a 4.25 pt pitch (80 per row), black ≈ 19 % at their center.
    static let dotPitch: CGFloat = 4.25
    static let dotSize: CGFloat = 1.1
    /// A color point: 44 pt across with a 5 pt white ring.
    static let pointSize: CGFloat = 44
    static let pointRing: CGFloat = 5
    /// − and +: 13 pt glyphs, centers 40 apart, 31.5 above the pad's bottom.
    static let padButtonSize: CGFloat = 24
    static let padButtonPitch: CGFloat = 40
    static let padButtonsBottom: CGFloat = 31.5
    static var swatchSize: CGFloat { CGFloat(Metrics.ThemePicker.swatchSize) }
    static var swatchPitch: CGFloat { CGFloat(Metrics.ThemePicker.swatchPitch) }
    /// Swatch rim: the swatch color × 0.92.
    static let swatchRimShade = 0.92
    /// Top of the swatch row (bubble y): center 380.5.
    static let presetRowTop: CGFloat = 368.5
    /// Page arrows: centers 23 and 333 (bubble x), so 25 pt between an arrow's center and the
    /// nearest swatch's edge.
    static let arrowWidth: CGFloat = 14
    static let arrowGap: CGFloat = 18
    /// Top of the slider / knob row (bubble y): center 452.
    static let controlsTop: CGFloat = 418
    static let knobSize: CGFloat = 68
    static let knobTrailing: CGFloat = 16
    /// The slider's track runs from 10 pt into the content (bubble x 18) to bubble x 241 (B159:
    /// a 2x capture of Arc's test Space, thumb center at x 192 for intensity 0.8).
    static let sliderLeading: CGFloat = 10
    static let sliderWidth: CGFloat = 223
    /// Ink opacities over the light fill: icons ≈ 48 % (#7F7D7C), − / + and arrows 43 %
    /// (#8C8988), dimmed arrow 13 % (#DBD7D5), selected segment block 8 % (#E0DDDB on the pad),
    /// pad 3.5 % (#F4F1EE on #FDF9F6). The dimmed − / + is inferred.
    static let iconInk = 0.48
    static let glyphInk = 0.43
    static let disabledGlyphInk = 0.13
    static let selectedSegmentInk = 0.08
    static let padInk = 0.035
    static let dotInk = 0.19
    /// Span of the gradient (0...1, top left to bottom right) between the first and last color of
    /// a gradient swatch: the read points sat 6.8 pt either side of the center along the 33.9 pt
    /// diagonal of a 24 pt swatch. [07 §8.5] inferred.
    static let gradientSwatchSampleSpread = 0.40
}

// MARK: - Pad background

/// Gray dot grid behind the color points. [06 §2] observed ("灰色点阵背景"); dense, B158 observed.
private struct DotGrid: View {
    let ink: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let step = ThemeEditorMetrics.dotPitch, dot = ThemeEditorMetrics.dotSize
            var dots = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(ink.opacity(opacity)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Wavy slider

/// Slider whose track is a sine wave. [06 §2] observed: "a wavy slider"; it sets the theme color's
/// intensity (B159). B158 / B159 observed: a 16 pt gray capsule track over the whole width, a thick
/// gray wave on it (4 pt stroke, 15.5 pt amplitude, 37.5 pt wavelength) that is lighter right of the
/// thumb, and a tall white pill thumb (27 × 58.5).
private struct WavySlider: View {
    @Binding var value: Double
    let ink: Color

    private let thumb = CGSize(width: 27, height: 58.5)
    private let trackHeight: CGFloat = 16
    private let waveInset: CGFloat = 5.5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let inset = thumb.width / 2
            let x = inset + CGFloat(value) * (width - 2 * inset)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(ink.opacity(0.06))
                    .frame(width: width, height: trackHeight)
                    .offset(y: (height - trackHeight) / 2)
                wave(from: waveInset, to: width - waveInset, height: height)
                    .stroke(ink.opacity(0.16), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                wave(from: waveInset, to: width - waveInset, height: height)
                    .stroke(ink.opacity(0.38), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Capsule()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .frame(width: thumb.width, height: thumb.height)
                    .position(x: x, y: height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value = ThemeControlMath.sliderValue(x: $0.location.x, width: width, inset: inset) }
            )
        }
        .frame(height: thumb.height)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.1, 1)
            case .decrement: value = max(value - 0.1, 0)
            @unknown default: break
            }
        }
    }

    private func wave(from start: CGFloat, to end: CGFloat, height: CGFloat) -> Path {
        Path { path in
            let amplitude: CGFloat = 15.5, wavelength: CGFloat = 37.5, mid = height / 2
            guard end > start else { return }
            path.move(to: CGPoint(x: start, y: mid))
            var x = start
            while x < end {
                x = min(x + 0.5, end)
                path.addLine(to: CGPoint(x: x, y: mid - sin((x - start) / wavelength * 2 * .pi) * amplitude))
            }
        }
    }
}

// MARK: - Ring knob

/// Round knob with a ring of dots. [06 §2] observed: "a round knob with a dotted ring"; it sets the
/// grain (B159). B158 observed: a 40 pt circle outline (1 pt, black ≈ 12 %),
/// 20 light gray 4.5 pt dots on a 31.75 pt radius all around, and a white 8 × 15.5 pill on the
/// ring that marks the value (at the top for 0, B159 observed; one clockwise turn to 1, inferred).
private struct RingKnob: View {
    @Binding var value: Double
    let ink: Color

    private let dotCount = 20
    private let ringRadius: CGFloat = 31.75

    var body: some View {
        let markerAngle = ThemeControlMath.knobAngle(value: value)
        return GeometryReader { proxy in
            ZStack {
                ForEach(0..<dotCount, id: \.self) { index in
                    let angle = Double(index) * 360 / Double(dotCount)
                    Circle()
                        .fill(ink.opacity(0.11))
                        .frame(width: 4.5, height: 4.5)
                        .offset(y: -ringRadius)
                        .rotationEffect(.degrees(angle))
                        // The marker covers the dot under it.
                        .opacity(Self.angularDistance(angle, markerAngle) < 360 / Double(dotCount) / 2 ? 0 : 1)
                }
                Circle()
                    .strokeBorder(ink.opacity(0.12), lineWidth: 1)
                    .frame(width: 40, height: 40)
                Capsule()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .frame(width: 8, height: 15.5)
                    .offset(y: -ringRadius)
                    .rotationEffect(.degrees(markerAngle))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = ThemeControlMath.knobValue(
                        dx: drag.location.x - proxy.size.width / 2, dy: drag.location.y - proxy.size.height / 2
                    )
                }
            )
        }
        .frame(width: ThemeEditorMetrics.knobSize, height: ThemeEditorMetrics.knobSize)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.1, 1)
            case .decrement: value = max(value - 0.1, 0)
            @unknown default: break
            }
        }
    }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(d, 360 - d)
    }
}
