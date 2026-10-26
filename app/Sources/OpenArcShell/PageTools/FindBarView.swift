import SwiftUI
import AppKit
import OpenArcDesign

// The find bar drawn over the top right of the focused web panel or split pane (B25). Its look is
// not in the spec: every value here is a local token, "own design".

/// Local tokens of the find bar. Own design (the spec records no find bar look).
enum FindBarTokens {
    /// Bar width. Own design.
    static let width: CGFloat = 300
    /// Bar height. Own design.
    static let height: CGFloat = 36
    /// Inset from the panel's top and right edges. Own design.
    static let margin: CGFloat = 10
    /// Corner radius of the bar. Own design.
    static let cornerRadius: CGFloat = 10
    /// Size of the ˄ ˅ ✕ buttons. Own design.
    static let buttonSize: CGFloat = 22
    /// Shadow under the bar. Own design.
    static let shadowRadius: CGFloat = 8
    static let shadowOpacity: Double = 0.18
    static let placeholder = "Find in page"
    /// Shown instead of "n of m" when the query matches nothing. Own wording.
    static let noMatches = "No matches"
}

/// What a web panel needs to draw the find bar for the tab it shows.
@MainActor
struct FindBarHost {
    let model: FindBarModel
    /// The model tab the panel shows.
    let tabID: UUID
}

extension ShellModel {
    /// The find bar host for the single web panel (the selected tab); nil without a selection.
    var findBarHost: FindBarHost? {
        selectedTabID.map { FindBarHost(model: findBar, tabID: $0) }
    }
}

/// The find bar; shown by `WebPanel` when `FindBarModel.isVisible(for:)` is true for its tab.
struct FindBarView: View {
    @ObservedObject var model: FindBarModel
    let tabID: UUID
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let query = Binding(
            get: { model.state(for: tabID).query },
            set: { model.updateQuery($0) }
        )
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: query, prompt: Text(FindBarTokens.placeholder))
                .textFieldStyle(.plain)
                .font(Typography.addressField.font)
                .focused($isFieldFocused)
                // Enter: next match; ⇧Enter: previous match. Own design (browser convention).
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { model.findPrevious() } else { model.findNext() }
                    return .handled
                }
                .onExitCommand { model.close(tabID) }
                .accessibilityIdentifier("openarc.findbar.field")
            if let text = statusText {
                Text(text)
                    .font(Typography.settingsCaption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            button("chevron.up", label: "Previous Match", action: model.findPrevious)
            button("chevron.down", label: "Next Match", action: model.findNext)
            button("xmark", label: "Close Find Bar") { model.close(tabID) }
        }
        .padding(.horizontal, 10)
        .frame(width: FindBarTokens.width, height: FindBarTokens.height)
        .background(
            RoundedRectangle(cornerRadius: FindBarTokens.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(FindBarTokens.shadowOpacity), radius: FindBarTokens.shadowRadius, y: 2)
        )
        .padding(.top, FindBarTokens.margin)
        .padding(.trailing, FindBarTokens.margin)
        .onAppear { focusField() }
        .onChange(of: model.focusRequest) { _, _ in focusField() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.findbar")
    }

    private var statusText: String? {
        guard let result = model.result(for: tabID) else { return nil }
        return result.matches == 0 && result.isFinal ? FindBarTokens.noMatches : FindBarModel.statusText(result)
    }

    /// Focuses the field and selects its text, so typing replaces a kept query.
    private func focusField() {
        isFieldFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: FindBarTokens.buttonSize, height: FindBarTokens.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Puts the find bar at the top right of a web panel when it is visible for the panel's tab.
struct FindBarOverlay: View {
    let host: FindBarHost
    @ObservedObject private var model: FindBarModel

    init(host: FindBarHost) {
        self.host = host
        self.model = host.model
    }

    var body: some View {
        if model.isVisible(for: host.tabID) {
            FindBarView(model: model, tabID: host.tabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}
