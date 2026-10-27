import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The onboarding flow (plan D9, restyled in B53 after the E6 capture, [06 §27]).
// Screen 1 ([06 §27.1]): the whole window is a blue grainy gradient with one huge headline and a
// text-less arrow button. Screen 2 ([06 §27.2]): a white left column that shows our D9 steps, one
// per screen, and a gradient right column, split by a scalloped edge, with a rounded browser-window
// demo that cycles through sample Spaces. Fields and the primary button follow [06 §27.3].
// Wording, the logo mark (an SF Symbol) and the demo mockups are our own ([06 §27.4] inferred: no
// Arc wording or images).

/// Sizes, colors, timing and wording of the onboarding flow. Measured values come from the E6
/// screenshots (1280 × 800 pt window, [06 §27]); the rest is our own choice.
enum OnboardingTokens {
    // MARK: Screen 1 [06 §27.1]
    /// Headline size: cap height ≈ 48 pt, so ≈ 64 pt. [06 §27.1] inferred.
    static let headlineSize: CGFloat = 64
    /// Headline line box to the arrow button. [06 §27.1] observed ≈ 26 pt.
    static let headlineToButton: CGFloat = 24
    /// The arrow button: 67 × 40, radius 8. [06 §27.1] observed.
    static let arrowButtonSize = CGSize(width: 67, height: 40)
    static let arrowButtonRadius: CGFloat = 8
    /// Fill ≈ #DDDEFB (white ≈ 85 % over the blue) and the arrow ≈ #3F4ED5. [06 §27.1] observed.
    static let arrowButtonFill = RGBAColor(hex: 0xDDDEFB)
    static let arrowInk = RGBAColor(hex: 0x3F4ED5)

    // MARK: Gradient [06 §27.1] observed samples; built from radial glows (inferred)
    static let gradientBase = RGBAColor(hex: 0x4650F0)        // left / middle ≈ #4B54F6, #5260E8
    static let gradientDeep = RGBAColor(hex: 0x2C30D0)        // upper middle ≈ #2C30D0–#3F4ED5
    static let gradientTopLeft = RGBAColor(hex: 0xA7B2F5)     // top-left glow ≈ #A7B2F5
    static let gradientBottomRight = RGBAColor(hex: 0x8FC5F9) // bottom-right ≈ #8FC5F9
    static let gradientTopRight = RGBAColor(hex: 0x3966F0)    // top right sample ≈ #3966F0
    /// Grain strength over the gradient. inferred (fine grain, as in the screenshots).
    static let grainOpacity: Double = 0.10

    // MARK: Screen 2 [06 §27.2]
    /// Left column fill ≈ #FFFEFF. [06 §27.2] observed.
    static let columnFill = RGBAColor(hex: 0xFFFEFF)
    /// Scalloped edge: period 17 pt, 4 pt peak to peak, centered on the half-width line.
    /// Measured on the E6 screenshot (bumps every 34 px at 2×); [06 §27.2] says ≈ 6 pt. observed.
    static let scallopPeriod: CGFloat = 17
    static let scallopAmplitude: CGFloat = 2
    /// Logo mark: ≈ 36 pt, top at y ≈ 110. [06 §27.2] observed.
    static let logoSize: CGFloat = 36
    static let contentTop: CGFloat = 109
    /// Title: black, extra bold, ≈ 34–36 pt. [06 §27.2] observed / inferred.
    static let titleSize: CGFloat = 34
    static let titleWidth: CGFloat = 400
    /// Body: ≈ #505050, 15 pt, 24 pt lines, centered, ≈ 330 pt wide. [06 §27.2] observed.
    static let bodyInk = RGBAColor(hex: 0x505050)
    static let bodySize: CGFloat = 15
    static let bodyLineSpacing: CGFloat = 6
    static let bodyWidth: CGFloat = 330
    /// Light gray button: #EFEFEF, 40 tall, radius 10. [06 §27.2] observed.
    static let grayButtonFill = RGBAColor(hex: 0xEFEFEF)
    static let grayButtonHeight: CGFloat = 40
    static let grayButtonRadius: CGFloat = 10
    static let buttonInk = RGBAColor(hex: 0x1D1D1F)
    /// Gray text link ≈ 13 pt. [06 §27.2] observed; color sampled ≈ #7A7A7A.
    static let linkSize: CGFloat = 13
    static let linkInk = RGBAColor(hex: 0x7A7A7A)
    /// Vertical gaps of the left column, from the screenshots. [06 §27.2] observed (± 2 pt).
    static let logoToTitle: CGFloat = 16
    static let titleToBody: CGFloat = 16
    static let bodyToControls: CGFloat = 24
    static let controlsToPrimary: CGFloat = 24
    static let primaryToLinks: CGFloat = 18

    // MARK: Fields and primary button [06 §27.3]
    /// Text field: 369 × 63, radius 8, 1 pt light gray border; focused 2 pt blue. observed.
    static let fieldSize = CGSize(width: 369, height: 63)
    static let fieldRadius: CGFloat = 8
    static let fieldBorder = RGBAColor(hex: 0xC9C9CC)
    static let accent = RGBAColor(hex: 0x3950F0)
    /// Floating label 12 pt at the top left; placeholder 18 pt when empty and unfocused.
    /// [06 §27.3] observed (sizes inferred from the glyphs).
    static let fieldLabelSmall: CGFloat = 12
    static let fieldLabelLarge: CGFloat = 18
    static let fieldTextSize: CGFloat = 17
    static let fieldInset: CGFloat = 15
    static let fieldLabelInk = RGBAColor(hex: 0x6E6E73)
    /// Primary button: 232 × 40, radius 8, blue #3950F0 → #2B3AEF; disabled text ≈ #7885FF.
    /// [06 §27.3] observed.
    static let primarySize = CGSize(width: 232, height: 40)
    static let primaryRadius: CGFloat = 8
    static let primaryTop = RGBAColor(hex: 0x3950F0)
    static let primaryBottom = RGBAColor(hex: 0x2B3AEF)
    static let primaryDisabledInk = RGBAColor(hex: 0x7885FF)
    static let buttonTextSize: CGFloat = 15

    // MARK: Demo card [06 §27.2]
    /// Top left of the card in a 1280 × 800 window: (736, 83), so 96 pt into the right column.
    /// The card runs out of the window on the right; its bottom sits 83 pt above the window's
    /// bottom edge. observed.
    static let demoInset = CGSize(width: 96, height: 83)
    static let demoWidth: CGFloat = 760
    static let demoMinHeight: CGFloat = 300
    static let demoRadius: CGFloat = 10
    static let demoSidebarWidth: CGFloat = 213

    // MARK: Motion (our own)
    /// Screen and step change. own design.
    static let transition = Animation.easeInOut(duration: 0.3)

    // MARK: Wording (our own)
    static let headline = "A browser that’s yours."
    static let skip = "Skip"
    static let back = "Back"
    static let next = "Continue"
    static let done = "Start Browsing"
    static let showAgainMenuItem = "Show Welcome Again"

    struct Copy {
        let symbol: String
        let title: String
        let message: String
    }

    /// One step's SF Symbol (our logo mark), title and message. own design (our wording).
    static func copy(for step: OnboardingModel.Step) -> Copy {
        switch step {
        case .welcome:
            return Copy(symbol: "sparkles", title: headline,
                        message: "A calm browser that keeps your tabs tidy in a sidebar.")
        case .space:
            return Copy(symbol: "square.stack.3d.up", title: "Name your first Space",
                        message: "Spaces keep different parts of your life apart. Give this one a name and a color.")
        case .importBookmarks:
            return Copy(symbol: "square.and.arrow.down", title: "Bring your bookmarks",
                        message: "Import bookmarks from another browser. They arrive as pinned tabs in a new Space.")
        case .defaultBrowser:
            return Copy(symbol: "globe", title: "Open links here",
                        message: "Make \(AppIdentity.displayName) your default browser so links from other apps open in it.")
        case .sync:
            return Copy(symbol: "icloud", title: "Sync with iCloud",
                        message: "Only your sidebar syncs: Spaces, pinned tabs, folders and favorites. History, passwords and open pages stay on this Mac.")
        case .done:
            return Copy(symbol: "checkmark.circle", title: "You’re all set",
                        message: "Press ⌘T to open a new tab, or ⌘L to search or type an address for the current tab.")
        }
    }

    /// Frame of the demo card in the right column (column coordinates). [06 §27.2] observed at
    /// 1280 × 800; other sizes keep the insets.
    static func demoCardFrame(columnSize: CGSize) -> CGRect {
        let height = max(demoMinHeight, columnSize.height - 2 * demoInset.height)
        return CGRect(x: demoInset.width, y: demoInset.height, width: demoWidth, height: height)
    }
}

// MARK: - Overlay

/// The onboarding screens, covering the whole window (no sidebar or web content). [06 §27.1]
struct OnboardingOverlay: View {
    @ObservedObject var onboarding: OnboardingModel
    /// The window's theme palette. Unused by the captured look (fixed blue and white), kept for
    /// the caller.
    let palette: ThemePalette

    var body: some View {
        ZStack {
            switch onboarding.screen {
            case .welcome:
                OnboardingWelcomeScreen(onboarding: onboarding)
                    .transition(.opacity)
            case .split:
                OnboardingSplitScreen(onboarding: onboarding)
                    .transition(.opacity)
            }
            // Escape skips from every screen. own design (D9).
            Button(OnboardingTokens.skip) { onboarding.skip() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .animation(OnboardingTokens.transition, value: onboarding.screen)
        .environment(\.colorScheme, .light)
        .onExitCommand { onboarding.skip() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.onboarding")
    }
}

// MARK: - Screen 1

/// Full-window gradient, headline and the arrow button. [06 §27.1] observed.
struct OnboardingWelcomeScreen: View {
    @ObservedObject var onboarding: OnboardingModel
    private typealias T = OnboardingTokens

    var body: some View {
        ZStack {
            OnboardingGradient()
            WindowDragArea()
            VStack(spacing: T.headlineToButton) {
                Text(T.headline)
                    .font(.system(size: T.headlineSize, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 40)
                    .accessibilityAddTraits(.isHeader)
                Button { onboarding.next() } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T.arrowInk.swiftUI)
                        .frame(width: T.arrowButtonSize.width, height: T.arrowButtonSize.height)
                        .background(RoundedRectangle(cornerRadius: T.arrowButtonRadius, style: .continuous)
                            .fill(T.arrowButtonFill.swiftUI))
                        .contentShape(Rectangle())
                }
                .buttonStyle(OnboardingPressStyle())
                .keyboardShortcut(.defaultAction)
                // No text on the button; its accessible name is the arrow. [06 §27.1] observed.
                .accessibilityLabel("→")
                .accessibilityIdentifier("openarc.onboarding.arrow")
            }
        }
    }
}

// MARK: - Screen 2

/// White left column with the step, scalloped edge, gradient right column with the demo.
/// [06 §27.2] observed.
struct OnboardingSplitScreen: View {
    @ObservedObject var onboarding: OnboardingModel
    @State private var carouselStart = Date()

    var body: some View {
        GeometryReader { proxy in
            let layout = OnboardingSplitLayout(windowSize: proxy.size)
            ZStack(alignment: .topLeading) {
                OnboardingTokens.columnFill.swiftUI
                WindowDragArea()
                rightColumn(layout)
                    .frame(width: layout.rightColumnFrame.width, height: layout.rightColumnFrame.height, alignment: .topLeading)
                    .clipShape(ScallopedColumn(edgeX: layout.edgeInset, period: OnboardingTokens.scallopPeriod,
                                               amplitude: OnboardingTokens.scallopAmplitude))
                    .offset(x: layout.rightColumnFrame.minX)
                OnboardingStepColumn(onboarding: onboarding)
                    .frame(width: layout.leftColumnWidth, height: proxy.size.height)
            }
        }
    }

    /// Gradient and demo card; one timeline drives the card's crossfade and the gradient drift.
    private func rightColumn(_ layout: OnboardingSplitLayout) -> some View {
        TimelineView(.periodic(from: carouselStart, by: OnboardingCarousel.interval)) { context in
            let index = OnboardingCarousel.index(start: carouselStart, now: context.date,
                                                 count: OnboardingDemoSample.samples.count)
            ZStack(alignment: .topLeading) {
                OnboardingGradient(phase: index, isColumn: true)
                WindowDragArea()
                OnboardingDemoColumn(onboarding: onboarding, sampleIndex: index, columnSize: layout.demoColumnSize)
                    .offset(x: layout.edgeInset)
            }
        }
    }
}

/// Geometry of the split screen. [06 §27.2] observed: two halves; the right column's frame
/// reaches a little left of the half line so the scallops can bulge both ways.
struct OnboardingSplitLayout: Equatable {
    let windowSize: CGSize

    var leftColumnWidth: CGFloat { (windowSize.width / 2).rounded() }
    /// Room left of the half line for the scallops.
    var edgeInset: CGFloat { OnboardingTokens.scallopAmplitude + 1 }
    var rightColumnFrame: CGRect {
        CGRect(x: leftColumnWidth - edgeInset, y: 0,
               width: windowSize.width - leftColumnWidth + edgeInset, height: windowSize.height)
    }
    /// The demo column starts at the half line.
    var demoColumnSize: CGSize { CGSize(width: windowSize.width - leftColumnWidth, height: windowSize.height) }
    /// The demo card in window coordinates.
    var demoCardFrame: CGRect {
        OnboardingTokens.demoCardFrame(columnSize: demoColumnSize).offsetBy(dx: leftColumnWidth, dy: 0)
    }
}

/// The right column's shape: everything right of a wavy vertical line at `edgeX`.
struct ScallopedColumn: Shape {
    let edgeX: CGFloat
    let period: CGFloat
    let amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: edgeX, y: rect.minY))
        let step: CGFloat = 1
        var y = rect.minY
        while y <= rect.maxY {
            path.addLine(to: CGPoint(x: Self.edge(at: y, center: edgeX, period: period, amplitude: amplitude), y: y))
            y += step
        }
        path.addLine(to: CGPoint(x: edgeX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// X of the edge at `y`: a sine wave around `center`. [06 §27.2] observed shape.
    static func edge(at y: CGFloat, center: CGFloat, period: CGFloat, amplitude: CGFloat) -> CGFloat {
        guard period > 0 else { return center }
        return center + amplitude * sin(2 * .pi * y / period)
    }
}

/// The blue grainy gradient of both screens: a base blue with radial glows (inferred: not a
/// linear gradient). `phase` shifts the glows a little per demo sample, so the right column's
/// light moves with the carousel ([06 §27.2] observed: "the gradient spots change slowly").
struct OnboardingGradient: View {
    var phase: Int = 0
    /// The right column of the split screen: no top-left glow there (it would sit on the
    /// scalloped edge); the light glow moves to the top right. [06 §27.2] observed samples
    /// (top right ≈ #5776F0 to light blue, elsewhere ≈ #4A53F6).
    var isColumn = false
    private typealias T = OnboardingTokens

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let span = max(size.width, size.height)
            let drift = CGFloat(phase % 4) * 0.06
            ZStack {
                T.gradientBase.swiftUI
                glow(T.gradientTopRight, at: UnitPoint(x: 1, y: 0), radius: span * 0.45)
                glow(T.gradientDeep, at: UnitPoint(x: 0.58 - drift, y: 0.22 + drift / 2), radius: span * 0.42)
                if isColumn {
                    glow(T.gradientTopLeft, at: UnitPoint(x: 1, y: 0), radius: span * (0.3 + drift))
                } else {
                    glow(T.gradientTopLeft, at: UnitPoint(x: 0, y: 0), radius: span * 0.24)
                }
                glow(T.gradientBottomRight, at: UnitPoint(x: 1 - drift / 2, y: 1), radius: span * (0.55 + drift))
                GrainOverlay(opacity: T.grainOpacity)
            }
            .animation(.easeInOut(duration: OnboardingCarousel.interval), value: phase)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: RGBAColor, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [color.swiftUI, color.swiftUI.opacity(0)], center: center,
                       startRadius: 0, endRadius: radius)
    }
}

// MARK: Left column

/// One D9 step, laid out like the captured left column: logo mark, extra-bold title, gray body,
/// the step's controls, the primary button and gray links. [06 §27.2, §27.3] observed layout.
struct OnboardingStepColumn: View {
    @ObservedObject var onboarding: OnboardingModel
    private typealias T = OnboardingTokens

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        let copy = T.copy(for: onboarding.step)
        return VStack(spacing: 0) {
            Image(systemName: copy.symbol)
                .font(.system(size: T.logoSize * 0.8, weight: .regular))
                .foregroundStyle(T.accent.swiftUI)
                .frame(width: T.logoSize, height: T.logoSize)
                .accessibilityHidden(true)
            Text(copy.title)
                .font(.system(size: T.titleSize, weight: .heavy))
                .foregroundStyle(Color.black)
                .multilineTextAlignment(.center)
                .frame(maxWidth: T.titleWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, T.logoToTitle)
                .accessibilityAddTraits(.isHeader)
            Text(copy.message)
                .font(.system(size: T.bodySize))
                .lineSpacing(T.bodyLineSpacing)
                .foregroundStyle(T.bodyInk.swiftUI)
                .multilineTextAlignment(.center)
                .frame(width: T.bodyWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, T.titleToBody)
            OnboardingStepControls(onboarding: onboarding)
                .padding(.top, T.bodyToControls)
            Button(onboarding.step == .done ? T.done : T.next) { onboarding.next() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(!onboarding.isContinueEnabled)
                .keyboardShortcut(.defaultAction)
                .padding(.top, T.controlsToPrimary)
                .accessibilityIdentifier("openarc.onboarding.continue")
            links
                .padding(.top, T.primaryToLinks)
        }
        .padding(.top, T.contentTop)
        .padding(.bottom, 40)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .id(onboarding.step)
        .transition(.opacity)
        .animation(OnboardingTokens.transition, value: onboarding.step)
    }

    @ViewBuilder
    private var links: some View {
        if onboarding.step != .done {
            HStack(spacing: 24) {
                if onboarding.canGoBack {
                    Button(T.back) { onboarding.back() }
                        .buttonStyle(OnboardingLinkStyle())
                }
                Button(T.skip) { onboarding.skip() }
                    .buttonStyle(OnboardingLinkStyle())
                    .accessibilityIdentifier("openarc.onboarding.skip")
            }
        }
    }
}

/// The controls of one step, between the body text and the primary button.
struct OnboardingStepControls: View {
    @ObservedObject var onboarding: OnboardingModel
    @State private var showsThemeEditor = false
    private typealias T = OnboardingTokens

    var body: some View {
        switch onboarding.step {
        case .welcome, .done:
            EmptyView()
        case .space:
            VStack(spacing: 16) {
                OnboardingTextField(label: "Space name", text: $onboarding.spaceName) {
                    if onboarding.isContinueEnabled { onboarding.next() }
                }
                swatches
                Button("More Colors…") { showsThemeEditor = true }
                    .buttonStyle(OnboardingLinkStyle())
                    .popover(isPresented: $showsThemeEditor, arrowEdge: .trailing) {
                        // Reuses the Edit Theme… bubble; edits apply live, the demo follows.
                        ThemeEditorView(theme: Binding(
                            get: { onboarding.themeDraft },
                            set: { onboarding.themeDraft = $0 }
                        ), systemAppearance: onboarding.systemAppearance)
                    }
            }
        case .importBookmarks:
            Button { onboarding.openImport() } label: {
                Label(onboarding.didOpenImport ? "Import More…" : "Import Bookmarks…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(OnboardingGrayButtonStyle())
        case .defaultBrowser:
            if onboarding.isDefaultBrowser {
                Label("\(AppIdentity.displayName) is your default browser", systemImage: "checkmark")
                    .font(.system(size: T.bodySize, weight: .medium))
                    .foregroundStyle(T.bodyInk.swiftUI)
                    .frame(height: T.grayButtonHeight)
            } else {
                Button { Task { await onboarding.makeDefaultBrowser() } } label: {
                    Label("Make Default Browser", systemImage: "globe")
                }
                .buttonStyle(OnboardingGrayButtonStyle())
            }
        case .sync:
            VStack(spacing: 8) {
                Toggle(isOn: Binding(get: { onboarding.syncEnabled }, set: { onboarding.setSyncEnabled($0) })) {
                    Text("Sync Sidebar")
                        .font(.system(size: T.buttonTextSize, weight: .medium))
                        .foregroundStyle(T.buttonInk.swiftUI)
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .frame(width: T.fieldSize.width, height: T.grayButtonHeight + 8)
                .background(RoundedRectangle(cornerRadius: T.grayButtonRadius, style: .continuous).fill(T.grayButtonFill.swiftUI))
                if !onboarding.isSyncBackendAvailable {
                    Text("iCloud sync is not available in this build yet; your choice is kept for later.")
                        .font(.system(size: 12))
                        .foregroundStyle(T.linkInk.swiftUI)
                        .multilineTextAlignment(.center)
                        .frame(width: T.bodyWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One row of theme colors for the Space. Our own control (the capture has no theme step).
    private var swatches: some View {
        let colors = ThemePresets.groups.first?.colors ?? []
        let current = onboarding.themeDraft.colors.first
        return HStack(spacing: 10) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button {
                    var draft = onboarding.themeDraft
                    draft.colors = [color]
                    onboarding.themeDraft = draft
                } label: {
                    Circle()
                        .fill(color.swiftUI)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(current == color ? T.accent.swiftUI : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Theme color \(colors.firstIndex(of: color).map { $0 + 1 } ?? 0)")
            }
        }
    }
}

// MARK: Controls [06 §27.3]

/// A text field with a floating label: an 18 pt placeholder while empty and unfocused, a 12 pt
/// label at the top left otherwise; 1 pt gray border, 2 pt blue while focused. Takes the focus
/// when it appears. [06 §27.3] observed.
struct OnboardingTextField: View {
    let label: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool
    private typealias T = OnboardingTokens

    var body: some View {
        let floats = isFocused || !text.isEmpty
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: T.fieldRadius, style: .continuous)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: T.fieldRadius, style: .continuous)
                .strokeBorder(isFocused ? T.accent.swiftUI : T.fieldBorder.swiftUI, lineWidth: isFocused ? 2 : 1)
            Text(label)
                .font(.system(size: floats ? T.fieldLabelSmall : T.fieldLabelLarge))
                .foregroundStyle(T.fieldLabelInk.swiftUI)
                .frame(height: floats ? 32 : T.fieldSize.height, alignment: floats ? .bottom : .center)
                .padding(.leading, T.fieldInset)
                .allowsHitTesting(false)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: T.fieldTextSize))
                .focused($isFocused)
                .onSubmit(onSubmit)
                .padding(.horizontal, T.fieldInset)
                .frame(height: 22)
                .padding(.top, 33)
                .opacity(floats ? 1 : 0.01)
                .accessibilityLabel(label)
        }
        .frame(width: T.fieldSize.width, height: T.fieldSize.height)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.15), value: floats)
        .onAppear { DispatchQueue.main.async { isFocused = true } }
    }
}

/// Blue fill, white text; disabled: the same fill with light blue text. [06 §27.3] observed.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private typealias T = OnboardingTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.buttonTextSize, weight: .medium))
            .foregroundStyle(isEnabled ? Color.white : T.primaryDisabledInk.swiftUI)
            .frame(width: T.primarySize.width, height: T.primarySize.height)
            .background(
                RoundedRectangle(cornerRadius: T.primaryRadius, style: .continuous)
                    .fill(LinearGradient(colors: [T.primaryTop.swiftUI, T.primaryBottom.swiftUI],
                                         startPoint: .top, endPoint: .bottom))
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Light gray button with an optional leading icon. [06 §27.2] observed.
struct OnboardingGrayButtonStyle: ButtonStyle {
    private typealias T = OnboardingTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.buttonTextSize, weight: .medium))
            .foregroundStyle(T.buttonInk.swiftUI)
            .padding(.horizontal, 20)
            .frame(height: T.grayButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: T.grayButtonRadius, style: .continuous)
                    .fill(T.grayButtonFill.swiftUI)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Plain gray text link. [06 §27.2] observed.
struct OnboardingLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: OnboardingTokens.linkSize, weight: .medium))
            .foregroundStyle(OnboardingTokens.linkInk.swiftUI.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}

/// Dims slightly while pressed. own design.
struct OnboardingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Demo card [06 §27.2]

/// One sample Space of the demo card. All names and colors are our own ([06 §27.4] inferred).
struct OnboardingDemoSample: Equatable {
    enum Page: Equatable { case photos, notes, shop, canvas }

    let spaceName: String
    let host: String
    let colors: [RGBAColor]
    let folders: [String]
    let tabs: [String]
    let page: Page

    /// The cycle: light gray, yellow-green, orange to pink, pink to purple ([06 §27.2] observed
    /// order of themes; the content is ours).
    static let samples: [OnboardingDemoSample] = [
        OnboardingDemoSample(spaceName: "Photos", host: "gallery.example", colors: [RGBAColor(hex: 0xDCDCE0)],
                             folders: ["Trips", "Portraits", "Ideas"], tabs: ["Gallery"], page: .photos),
        OnboardingDemoSample(spaceName: "Garden", host: "notes.example", colors: [RGBAColor(hex: 0x9EDC6E), RGBAColor(hex: 0xE2E06A)],
                             folders: ["Seeds", "Beds"], tabs: ["Planner", "Weather"], page: .notes),
        OnboardingDemoSample(spaceName: "Home", host: "shop.example", colors: [RGBAColor(hex: 0xF2B04A), RGBAColor(hex: 0xE5677A)],
                             folders: ["Read Later", "Shopping", "Trip"], tabs: ["Kitchen", "Magazine", "Lamps"], page: .shop),
        OnboardingDemoSample(spaceName: "Studio", host: "board.example", colors: [RGBAColor(hex: 0xF08BC8), RGBAColor(hex: 0x9B7BEA)],
                             folders: ["Sketches", "References"], tabs: ["Moodboard"], page: .canvas),
    ]
}

/// The right column's card: the cycling samples, or the Space being named on the Space step.
struct OnboardingDemoColumn: View {
    @ObservedObject var onboarding: OnboardingModel
    let sampleIndex: Int
    let columnSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = OnboardingTokens.demoCardFrame(columnSize: columnSize)
        ZStack(alignment: .topLeading) {
            if onboarding.showsLiveSpaceDemo {
                OnboardingDemoCard(sample: liveSample, palette: livePalette)
                    .transition(.opacity)
            } else {
                let samples = OnboardingDemoSample.samples
                ZStack(alignment: .topLeading) {
                    ForEach(samples.indices, id: \.self) { i in
                        OnboardingDemoCard(sample: samples[i],
                                           palette: ThemeDerivation.palette(forStyle: ThemeStyle(colors: samples[i].colors)))
                            .opacity(i == sampleIndex ? 1 : 0)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: OnboardingCarousel.crossfade), value: sampleIndex)
                .transition(.opacity)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTokens.demoRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: OnboardingTokens.demoRadius, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        )
        .offset(x: frame.minX, y: frame.minY)
        // Report the column's size, not the card's: the card runs out of the window.
        .frame(width: columnSize.width, height: columnSize.height, alignment: .topLeading)
        .animation(OnboardingTokens.transition, value: onboarding.showsLiveSpaceDemo)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var livePalette: ThemePalette {
        ThemeEditorView.palette(for: onboarding.themeDraft, systemAppearance: onboarding.systemAppearance)
    }

    private var liveSample: OnboardingDemoSample {
        let name = onboarding.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return OnboardingDemoSample(spaceName: name.isEmpty ? "Space" : name, host: "start.example",
                                    colors: onboarding.themeDraft.colors, folders: ["Reading", "Projects"],
                                    tabs: ["Start Page"], page: .notes)
    }
}

/// A browser window drawn from shapes: themed sidebar on the left, a page on the right.
/// Positions are scaled from the E6 screenshots (inferred), the content is ours.
struct OnboardingDemoCard: View {
    let sample: OnboardingDemoSample
    let palette: ThemePalette
    private typealias T = OnboardingTokens

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background
                sidebar
                    .frame(width: T.demoSidebarWidth, height: proxy.size.height, alignment: .top)
                OnboardingDemoPage(page: sample.page, accent: palette.backgroundGradientColors.first ?? palette.windowBackground)
                    .frame(width: proxy.size.width - T.demoSidebarWidth - 8, height: proxy.size.height - 16)
                    .background(palette.webPanelBackground.swiftUI)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 2)
                    .offset(x: T.demoSidebarWidth, y: 8)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        let colors = palette.backgroundGradientColors
        if colors.count > 1 {
            LinearGradient(colors: colors.map(\.swiftUI), startPoint: .top, endPoint: .bottom)
        } else {
            palette.windowBackground.swiftUI
        }
    }

    private var ink: Color { palette.primaryText.swiftUI }
    private var dim: Color { palette.secondaryText.swiftUI }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window buttons and toolbar icons.
            HStack(spacing: 8) {
                ForEach([0xEC6A5E, 0xF4BF4F, 0x61C554], id: \.self) { hex in
                    Circle().fill(RGBAColor(hex: UInt32(hex)).swiftUI).frame(width: 10, height: 10)
                }
                Image(systemName: "sidebar.left").padding(.leading, 8)
                Spacer()
                Image(systemName: "arrow.left")
                Image(systemName: "arrow.right").opacity(0.4)
                Image(systemName: "arrow.clockwise")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(dim)
            .frame(height: 20)
            .padding(.top, 19)
            .padding(.horizontal, 14)
            // Address field.
            HStack {
                Text(sample.host).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.8))
                Spacer()
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(dim)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.controlFill.swiftUI))
            .padding(.horizontal, 8)
            .padding(.top, 12)
            // Favorites.
            HStack(spacing: 7) {
                ForEach(["envelope.fill", "play.rectangle.fill", "calendar", "music.note"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(ink.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.controlFill.swiftUI))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)
            Text(sample.spaceName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dim)
                .padding(.leading, 18)
                .padding(.top, 14)
            ForEach(sample.folders, id: \.self) { folder in
                row(symbol: "folder", title: folder, bold: true)
            }
            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
                .padding(.horizontal, 18).padding(.vertical, 8)
            row(symbol: "plus", title: "New Tab", bold: false, faded: true)
            ForEach(Array(sample.tabs.enumerated()), id: \.offset) { index, tab in
                row(symbol: "doc.text", title: tab, bold: false, selected: index == 0)
            }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "archivebox")
                Spacer()
                HStack(spacing: 10) {
                    ForEach(0..<3) { i in Circle().fill(ink.opacity(i == 0 ? 0.6 : 0.25)).frame(width: 6, height: 6) }
                }
                Spacer()
                Image(systemName: "plus")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dim)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    private func row(symbol: String, title: String, bold: Bool, faded: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
            Text(title).font(.system(size: 13, weight: bold ? .semibold : .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(faded ? dim : (selected ? palette.selectedTabText.swiftUI : ink))
        .padding(.horizontal, 10)
        .frame(height: 35)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? palette.selectedTabFill.swiftUI : .clear)
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// The page of a demo card, drawn from plain shapes (no images).
struct OnboardingDemoPage: View {
    let page: OnboardingDemoSample.Page
    let accent: RGBAColor

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            switch page {
            case .photos:
                // Two columns of tiles in soft gradients.
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        tile([0x9CC9E8, 0xE8DCC2], height: 260)
                        tile([0x2E3B2C, 0x8A9A6B], height: 300)
                    }
                    VStack(spacing: 12) {
                        tile([0xE9EEF0, 0x9AA3A8], height: 170)
                        tile([0xB9C6CC, 0x6E5A44], height: 360)
                    }
                }
                .padding(10)
                .frame(width: w, alignment: .topLeading)
            case .notes:
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<3) { i in
                        HStack(spacing: 14) {
                            tile(i == 0 ? [0x6E8F5A, 0xC9D7A8] : i == 1 ? [0xE5D9C3, 0xB89F7A] : [0x7C8A99, 0xC8D0D8], height: 120)
                                .frame(width: 140)
                            VStack(alignment: .leading, spacing: 8) {
                                bar(width: 200, height: 10, opacity: 0.7)
                                bar(width: 160, height: 10, opacity: 0.7)
                                bar(width: 220, height: 7, opacity: 0.3)
                                bar(width: 120, height: 7, opacity: 0.3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.08), radius: 3))
                    }
                }
                .padding(.top, 120)
                .padding(.leading, 40)
                .frame(width: w + 200, alignment: .topLeading)
            case .shop:
                VStack(alignment: .leading, spacing: 18) {
                    tile([0x3A2E26, 0x8C7158], height: 170)
                        .padding(.leading, 30)
                    HStack(spacing: 8) { bar(width: 50, height: 8, opacity: 0.8); bar(width: 60, height: 8, opacity: 0.4) }
                        .padding(.leading, 100)
                    HStack(spacing: 30) {
                        ForEach(0..<2) { i in
                            VStack(alignment: .leading, spacing: 8) {
                                tile(i == 0 ? [0xF2F2F0, 0x8E8A84] : [0xEFE9E4, 0xC9BFB4], height: 190).frame(width: 180)
                                bar(width: 150, height: 9, opacity: 0.6)
                                bar(width: 60, height: 9, opacity: 0.35)
                            }
                        }
                    }
                    .padding(.leading, 100)
                }
                .frame(width: w + 200, alignment: .topLeading)
            case .canvas:
                ZStack(alignment: .topLeading) {
                    Circle().fill(accent.swiftUI.opacity(0.55)).frame(width: 150, height: 150).offset(x: 60, y: 90)
                    RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.92)).frame(width: 220, height: 150).offset(x: 230, y: 60)
                    RoundedRectangle(cornerRadius: 4).strokeBorder(accent.swiftUI, lineWidth: 3).frame(width: 160, height: 110).offset(x: 140, y: 290)
                    tile([0xF3C6DC, 0xA996E8], height: 180).frame(width: 200).offset(x: 340, y: 260)
                    HStack(spacing: 16) {
                        ForEach(["cursorarrow", "photo", "textformat", "circle", "square", "arrow.up.right", "scribble"], id: \.self) {
                            Image(systemName: $0).font(.system(size: 14))
                        }
                    }
                    .foregroundStyle(Color.black.opacity(0.6))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white).shadow(color: .black.opacity(0.12), radius: 4))
                    .offset(x: 20, y: max(0, proxy.size.height - 60))
                }
                .frame(width: w, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .clipped()
    }

    private func tile(_ hexes: [UInt32], height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: hexes.map { RGBAColor(hex: $0).swiftUI }, startPoint: .top, endPoint: .bottom))
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }

    private func bar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule().fill(Color.black.opacity(opacity * 0.5)).frame(width: width, height: height)
    }
}

// MARK: - Window

/// Lets the window be dragged by the onboarding background (the window has no visible title bar).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// While onboarding is up the window cannot zoom: the zoom button is disabled ([06 §27.1]
/// observed) and turned back on when the flow goes away. Always attached (by `OnboardingLayer`)
/// and driven by `isOnboardingShown`, so the button comes back without relying on teardown.
struct OnboardingWindowConfigurator: NSViewRepresentable {
    let isOnboardingShown: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isOnboardingShown = isOnboardingShown
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.isOnboardingShown = isOnboardingShown
    }

    final class ProbeView: NSView {
        var isOnboardingShown = false {
            didSet { if oldValue != isOnboardingShown { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let button = window?.standardWindowButton(.zoomButton) else { return }
            let isEnabled = !isOnboardingShown
            // Written outside the SwiftUI update pass (B28: no window writes from inside it).
            DispatchQueue.main.async { if button.isEnabled != isEnabled { button.isEnabled = isEnabled } }
        }
    }
}

// MARK: - Menu and layer

/// Help ▸ Show Welcome Again: re-runs onboarding in the key browser window. The menu placement
/// is inferred (D9 own design). It replaces the system "<App> Help" item: [01 §Help] observed no
/// such item (and no icons in the Help menu, [01 §菜单项图标与缩进]); we ship no help book. B62.
struct OnboardingCommands: Commands {
    let controller: WorkspaceController
    @FocusedObject private var focused: ShellModel?

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(OnboardingTokens.showAgainMenuItem) {
                if let window = focused ?? controller.activeWindow { controller.onboarding.showAgain(in: window) }
            }
            .disabled((focused ?? controller.activeWindow).map { $0.isIncognito } ?? true)
        }
    }
}

/// Shows the overlay only in the window that hosts the flow. Observes the onboarding model so
/// the window updates when the flow starts or ends.
struct OnboardingLayer: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var onboarding: OnboardingModel
    let palette: ThemePalette

    var body: some View {
        ZStack {
            if onboarding.isShown(in: model) {
                OnboardingOverlay(onboarding: onboarding, palette: palette)
                    .transition(.opacity)
            }
        }
        .animation(OnboardingTokens.transition, value: onboarding.isShown(in: model))
        .background(OnboardingWindowConfigurator(isOnboardingShown: onboarding.isShown(in: model)))
    }
}
