import SwiftUI
import OpenArcModel
import OpenArcDesign

/// The theme bubble. [06 §2] observed, top to bottom: three icon segments (automatic / light /
/// dark), a dot-grid color pad with the hint "Tap to pick a color for this space" and − / + buttons
/// at its bottom, one row of nine round swatches with left and right arrows that page through named
/// groups, and at the bottom a wavy slider (grain, inferred) and a ring knob (brightness, inferred).
/// [07 §6] observed: visible bubble ≈ 356 × 508, radius 20, padding 8, a 340 × 340 dot pad,
/// 24 pt preset swatches at a 29.5 pitch, 32 pt segment buttons at a 40 pitch; light ≈ #FDF1FA
/// (near white tinted by the theme).
/// With the dark segment (or automatic on a dark system) the bubble goes dark: the theme color
/// darkened, light icons, a pale theme-colored block on the selected segment, a dimmed dot grid.
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

    init(theme: Binding<SpaceThemeDraft>, systemAppearance: ResolvedAppearance = .light) {
        _theme = theme
        self.systemAppearance = systemAppearance
        _presetPage = State(initialValue: ThemePresets.pageContaining(theme.wrappedValue.colors.first))
    }

    /// The bubble follows the theme being edited, so switching the segment restyles it at once.
    private var palette: ThemePalette {
        ThemeDerivation.palette(forStyle: theme.style, systemAppearance: systemAppearance)
    }

    /// Ink for icons, labels and tracks: black in light, white in dark.
    private var ink: Color { palette.floatingPanelInk.swiftUI }

    var body: some View {
        VStack(spacing: M.sectionSpacing) {
            appearanceSegments
            colorPad
            presetRow
            bottomControls
        }
        .padding(M.padding)
        .frame(width: M.size.width, height: M.size.height)
        .background(palette.floatingPanelBackground.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.themeEditor")
    }

    // MARK: Appearance

    private var appearanceSegments: some View {
        HStack(spacing: M.segmentPitch - M.segmentSize) {
            segment(.automatic, symbol: "sparkles", label: "Automatic")
            segment(.light, symbol: "sun.max", label: "Light")
            segment(.dark, symbol: "moon", label: "Dark")
        }
        .frame(maxWidth: .infinity)
    }

    private func segment(_ appearance: ThemeAppearance, symbol: String, label: String) -> some View {
        let selected = theme.appearance == appearance
        return Button { theme.appearance = appearance } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.opacity(selected ? 0.85 : 0.5))
                .frame(width: M.segmentSize, height: M.segmentSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? palette.floatingPanelSelection.swiftUI : Color.clear)
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
                RoundedRectangle(cornerRadius: M.padCornerRadius, style: .continuous).fill(ink.opacity(0.04))
                DotGrid(ink: ink, opacity: palette.isDark ? 0.12 : 0.18)
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
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(width: M.pointSize, height: M.pointSize)
                        .position(x: p.x * size.width, y: p.y * size.height)
                        .allowsHitTesting(false)
                }
                padButtons
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let position = ThemePad.clamped(CGPoint(
                            x: value.location.x / max(size.width, 1), y: value.location.y / max(size.height, 1)
                        ))
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

    /// − and + at the bottom of the pad; both gray when no point is placed. [06 §2] observed.
    private var padButtons: some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                Spacer()
                padButton("minus", label: "Remove color", enabled: theme.canRemovePoint) { theme.removeLastPoint() }
                padButton("plus", label: "Add color", enabled: theme.canAddPoint) { theme.addPoint() }
            }
            .padding(8)
        }
    }

    private func padButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.black.opacity(enabled ? 0.7 : 0.25))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.95 : 0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Presets

    private var presetRow: some View {
        let group = ThemePresets.groups[presetPage]
        return VStack(spacing: 6) {
            HStack(spacing: M.swatchPitch - M.swatchSize) {
                pageArrow("chevron.left", step: -1)
                ForEach(Array(group.colors.enumerated()), id: \.offset) { _, color in
                    Button { theme.applyPreset(color) } label: {
                        Circle().fill(color.swiftUI)
                            .frame(width: M.swatchSize, height: M.swatchSize)
                            .overlay(Circle().strokeBorder(ink.opacity(0.12), lineWidth: 0.5))
                            .overlay(Circle().strokeBorder(ink.opacity(theme.colors == [color] ? 0.8 : 0), lineWidth: 1.5).padding(-2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(group.name) color")
                }
                pageArrow("chevron.right", step: 1)
            }
            Text(group.name)
                .font(Typography.panelHeader.font)
                .foregroundStyle(ink.opacity(0.45))
                .accessibilityIdentifier("openarc.themeEditor.groupName")
        }
    }

    private func pageArrow(_ symbol: String, step: Int) -> some View {
        let target = ThemePresets.page(after: presetPage, step: step)
        return Button { presetPage = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink.opacity(target == presetPage ? 0.2 : 0.6))
                .frame(width: 16, height: M.swatchSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == presetPage)
        .accessibilityLabel(step < 0 ? "Previous colors" : "Next colors")
    }

    // MARK: Bottom controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            WavySlider(value: $theme.grain, ink: ink)
                .accessibilityLabel("Texture")
                .accessibilityIdentifier("openarc.themeEditor.grain")
            RingKnob(value: $theme.brightness, ink: ink)
                .accessibilityLabel("Brightness")
                .accessibilityIdentifier("openarc.themeEditor.brightness")
        }
        .frame(height: M.knobSize)
    }
}

/// Sizes of the bubble. [07 §6] observed (size, radius, padding, pad, swatches, segments); the
/// rest is our own layout to fit that size (unknown).
enum ThemeEditorMetrics {
    static var size: CGSize { CGSize(width: Metrics.ThemePicker.size.width, height: Metrics.ThemePicker.size.height) }
    static var cornerRadius: CGFloat { CGFloat(Metrics.ThemePicker.cornerRadius) }
    static var padding: CGFloat { CGFloat(Metrics.ThemePicker.padding) }
    static let sectionSpacing: CGFloat = 12
    static var segmentSize: CGFloat { CGFloat(Metrics.ThemePicker.segmentButtonSize) }
    static var segmentPitch: CGFloat { CGFloat(Metrics.ThemePicker.segmentButtonPitch) }
    static var padSize: CGFloat { CGFloat(Metrics.ThemePicker.dotGridSize) }
    static let padCornerRadius: CGFloat = 14
    static let pointSize: CGFloat = 24
    static var swatchSize: CGFloat { CGFloat(Metrics.ThemePicker.swatchSize) }
    static var swatchPitch: CGFloat { CGFloat(Metrics.ThemePicker.swatchPitch) }
    static let knobSize: CGFloat = 36
}

// MARK: - Pad background

/// Gray dot grid behind the color points. [06 §2] observed ("灰色点阵背景").
private struct DotGrid: View {
    let ink: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 17
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(ink.opacity(opacity)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Wavy slider

/// Slider whose track is a sine wave. [06 §2] observed: "a wavy slider"; its meaning (texture/grain
/// strength) is inferred. The part left of the thumb is drawn dark, the rest gray.
private struct WavySlider: View {
    @Binding var value: Double
    let ink: Color

    private let thumb: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let inset = thumb / 2
            let x = inset + CGFloat(value) * (width - 2 * inset)
            ZStack(alignment: .topLeading) {
                wave(width: width, height: height).stroke(ink.opacity(0.18), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                wave(width: width, height: height)
                    .stroke(ink.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: thumb, height: thumb)
                    .position(x: x, y: height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value = ThemeControlMath.sliderValue(x: $0.location.x, width: width, inset: inset) }
            )
        }
        .frame(height: 24)
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

    private func wave(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            let amplitude: CGFloat = 3.5, wavelength: CGFloat = 16, mid = height / 2
            path.move(to: CGPoint(x: 0, y: mid))
            var x: CGFloat = 0
            while x <= width {
                path.addLine(to: CGPoint(x: x, y: mid + sin(x / wavelength * 2 * .pi) * amplitude))
                x += 1
            }
        }
    }
}

// MARK: - Ring knob

/// Round knob with a ring of dots. [06 §2] observed: "a round knob with a dotted ring"; its meaning
/// (brightness/contrast) is inferred. Dots up to the current value are dark.
private struct RingKnob: View {
    @Binding var value: Double
    let ink: Color

    private let dotCount = 12

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2 - 2.5
            ZStack {
                ForEach(0..<dotCount, id: \.self) { index in
                    let fraction = Double(index) / Double(dotCount - 1)
                    let angle = Angle.degrees(ThemeControlMath.knobAngle(value: fraction))
                    Circle()
                        .fill(ink.opacity(fraction <= value + 0.001 ? 0.7 : 0.18))
                        .frame(width: 3, height: 3)
                        .offset(y: -radius)
                        .rotationEffect(angle)
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: side - 12, height: side - 12)
                Capsule()
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 2, height: 5)
                    .offset(y: -(side - 12) / 2 + 4)
                    .rotationEffect(.degrees(ThemeControlMath.knobAngle(value: value)))
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
}
