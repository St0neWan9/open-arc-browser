import SwiftUI
import OpenArcEngine
import OpenArcDesign

// Engine info bars (plan C23) drawn by the shell above a tab's page. [00 §A] inferred (analysis):
// "Engine info bars (confirmation strips above the page), not only translation", drawn by the
// shell; the spec records no look, so the strip is our own, simple and native: one line of the
// engine's message, its link, its buttons and a close button, on the window's background with a
// hairline under it. The page moves down under the strips; it is never covered.

/// Local tokens of the info bar strip. All unknown (own design).
enum InfoBarLocalTokens {
    static let height: CGFloat = 36
    static let horizontalPadding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let iconSize: CGFloat = 13
}

/// The open info bars of one tab, stacked above its page, oldest on top.
struct InfoBarStack: View {
    @ObservedObject var center: DialogCenter
    let tabID: EngineTabID

    var body: some View {
        let bars = center.infoBars(for: tabID)
        if !bars.isEmpty {
            VStack(spacing: 0) {
                ForEach(bars) { bar in
                    InfoBarStrip(center: center, bar: bar)
                        .id(bar.id)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// One info bar: icon, message, link, buttons (Cancel, then OK), close button.
struct InfoBarStrip: View {
    let center: DialogCenter
    let bar: InfoBarRequest

    var body: some View {
        let presentation = DialogPresentation(.infoBar(bar))
        HStack(spacing: InfoBarLocalTokens.spacing) {
            Image(systemName: "info.circle")
                .font(.system(size: InfoBarLocalTokens.iconSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(bar.message)
                .font(Typography.settingsBody.font)
                .lineLimit(1)
                .truncationMode(.head)
                .help(bar.message)
            if let link = bar.linkTitle {
                Button(link) { center.answer(bar.id, with: .infoBar(.openLink)) }
                    .buttonStyle(.link)
                    .font(Typography.settingsBody.font)
            }
            Spacer(minLength: InfoBarLocalTokens.spacing)
            ForEach(Array(presentation.buttons.enumerated()), id: \.offset) { index, title in
                Button(title) {
                    let answer = DialogPresentation.answer(for: .infoBar(bar), button: index, fieldValues: [], checkbox: false)
                    center.answer(bar.id, with: answer)
                }
                .controlSize(.small)
            }
            if bar.isCloseable {
                Button {
                    center.answer(bar.id, with: .infoBar(.close))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, InfoBarLocalTokens.horizontalPadding)
        .frame(height: InfoBarLocalTokens.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.infoBar")
    }
}
