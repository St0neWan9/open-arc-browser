import SwiftUI
import AppKit
import OpenArcDesign

// The onboarding card flow (plan D9). OWN DESIGN: Arc's onboarding was never captured (plan E6).
// Wording, sizes and motion below are our own choices, not measured from anything.

/// Sizes, timing and wording of the onboarding flow. All "own design" (D9), none from the spec.
enum OnboardingTokens {
    static let cardWidth: CGFloat = 440                 // own design (wider for the 14 pt body, B16)
    /// The card is sized to its content up to this height; taller content scrolls (B26). own design.
    static let cardMaxHeight: CGFloat = 640
    /// Scale of the theme bubble inside the Space step. own design (B16).
    static let themeEditorScale: CGFloat = 0.55
    /// Least space kept between the card and the window edges. own design.
    static let windowMargin: CGFloat = 40
    static let cardCornerRadius: CGFloat = 16           // own design
    static let cardPadding: CGFloat = 28                // own design
    static let cardShadowRadius: CGFloat = 24           // own design
    static let symbolSize: CGFloat = 34                 // own design
    static let stepDotSize: CGFloat = 6                 // own design
    /// Dims the themed background behind the card so the card reads as the focus. own design.
    static let scrimOpacity: Double = 0.18
    /// Card appear/disappear and step change. own design.
    static let transition = Animation.spring(response: 0.35, dampingFraction: 0.88)

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

    /// One card's SF Symbol, title and message. own design (our wording).
    static func copy(for step: OnboardingModel.Step) -> Copy {
        switch step {
        case .welcome:
            return Copy(symbol: "sparkles", title: "Welcome to \(AppIdentity.displayName)",
                        message: "A calm browser that keeps your tabs tidy in a sidebar. A few quick choices and you’re ready.")
        case .space:
            return Copy(symbol: "square.stack.3d.up", title: "Name Your First Space",
                        message: "Spaces keep different parts of your life apart. Give this one a name and a color.")
        case .importBookmarks:
            return Copy(symbol: "square.and.arrow.down", title: "Bring Your Bookmarks",
                        message: "Import bookmarks from another browser. They arrive as pinned tabs in a new Space.")
        case .defaultBrowser:
            return Copy(symbol: "globe", title: "Open Links Here",
                        message: "Make \(AppIdentity.displayName) your default browser so links from other apps open in it.")
        case .sync:
            return Copy(symbol: "icloud", title: "Sync with iCloud",
                        message: "Only your sidebar syncs: Spaces, pinned tabs, folders and favorites. History, passwords and open pages stay on this Mac.")
        case .done:
            return Copy(symbol: "checkmark.circle", title: "You’re All Set",
                        message: "Press ⌘T to open a new tab, or ⌘L to search or type an address for the current tab.")
        }
    }
}

/// Dims the window and shows the current onboarding card centered over the themed background.
struct OnboardingOverlay: View {
    @ObservedObject var onboarding: OnboardingModel
    let palette: ThemePalette

    var body: some View {
        ZStack {
            Color.black.opacity(OnboardingTokens.scrimOpacity)
                .contentShape(Rectangle())
            OnboardingCard(onboarding: onboarding)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: OnboardingCardFrameKey.self, value: proxy.frame(in: .global))
                })
                .padding(OnboardingTokens.windowMargin)
                .id(onboarding.step)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .animation(OnboardingTokens.transition, value: onboarding.step)
        .onExitCommand { onboarding.skip() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.onboarding")
    }
}

/// The card's frame in the overlay, for layout tests.
struct OnboardingCardFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// One step's card.
struct OnboardingCard: View {
    @ObservedObject var onboarding: OnboardingModel
    private typealias T = OnboardingTokens

    var body: some View {
        // Compact card: as tall as its content (B26), never taller than `cardMaxHeight` or the
        // space offered. When the content does not fit, it scrolls and the footer stays in view.
        OnboardingHeightCap(maxHeight: T.cardMaxHeight) {
            VStack(spacing: 16) {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView(.vertical) { content }
                        .scrollIndicators(.automatic)
                }
                footer
            }
            .padding(T.cardPadding)
            .frame(width: T.cardWidth)
        }
        .background(
            RoundedRectangle(cornerRadius: T.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: T.cardShadowRadius, y: 8)
        )
    }

    /// Symbol, title, message and the step's controls.
    private var content: some View {
        let copy = T.copy(for: onboarding.step)
        return VStack(spacing: 16) {
            Image(systemName: copy.symbol)
                .font(.system(size: T.symbolSize, weight: .regular))
                .foregroundStyle(.secondary)
            // Own design (D9) on the shared type scale: sheet title Bold 17, body Regular 14. [07 §3]
            Text(copy.title).font(Typography.onboardingTitle.font).multilineTextAlignment(.center)
            Text(copy.message)
                .font(Typography.onboardingBody.font).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            stepContent
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch onboarding.step {
        case .welcome, .done:
            EmptyView()
        case .space:
            VStack(spacing: 12) {
                TextField("Space name", text: $onboarding.spaceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onboarding.next() }
                // Reuses the Edit Theme… bubble; edits apply live to the window background.
                // The bubble has its measured size (356 × 508, [07 §6]); inside this card (own
                // design) it is drawn smaller so the card stays compact (B26).
                ThemeEditorView(theme: Binding(
                    get: { onboarding.themeDraft },
                    set: { onboarding.themeDraft = $0 }
                ), systemAppearance: onboarding.systemAppearance)
                .shadow(color: .black.opacity(0.08), radius: 4)
                .scaleEffect(T.themeEditorScale)
                .frame(width: ThemeEditorMetrics.size.width * T.themeEditorScale,
                       height: ThemeEditorMetrics.size.height * T.themeEditorScale)
            }
        case .importBookmarks:
            Button(onboarding.didOpenImport ? "Import More…" : "Import Bookmarks…") { onboarding.openImport() }
        case .defaultBrowser:
            if onboarding.isDefaultBrowser {
                Label("\(AppIdentity.displayName) is your default browser", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                Button("Make Default Browser") { Task { await onboarding.makeDefaultBrowser() } }
            }
        case .sync:
            VStack(spacing: 6) {
                Toggle("Sync Sidebar", isOn: Binding(
                    get: { onboarding.syncEnabled },
                    set: { onboarding.setSyncEnabled($0) }
                ))
                .toggleStyle(.switch)
                if !onboarding.isSyncBackendAvailable {
                    Text("iCloud sync is not available in this build yet; your choice is kept for later.")
                        .font(Typography.onboardingCaption.font).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            stepDots
            HStack {
                if onboarding.step != .done {
                    // Escape skips from every step. own design.
                    Button(T.skip) { onboarding.skip() }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if onboarding.canGoBack {
                    Button(T.back) { onboarding.back() }
                }
                Button(onboarding.step == .done ? T.done : T.next) { onboarding.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == onboarding.step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2))
                    .frame(width: T.stepDotSize, height: T.stepDotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Offers its content at most `maxHeight` and reports the content's own size, so the card never
/// grows to fill the window (a `.frame(maxHeight:)` would take the whole offer up to the cap).
struct OnboardingHeightCap: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(cappedProposal(proposal))
        return CGSize(width: size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func cappedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? maxHeight, maxHeight))
    }
}

/// Help ▸ Show Welcome Again: re-runs onboarding in the key browser window. The menu placement
/// is inferred (D9 own design).
struct OnboardingCommands: Commands {
    let controller: WorkspaceController
    @FocusedObject private var focused: ShellModel?

    var body: some Commands {
        CommandGroup(before: .help) {
            Button(OnboardingTokens.showAgainMenuItem) {
                if let window = focused ?? controller.activeWindow { controller.onboarding.showAgain(in: window) }
            }
            .disabled((focused ?? controller.activeWindow).map { $0.isIncognito } ?? true)
            Divider()
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
    }
}
