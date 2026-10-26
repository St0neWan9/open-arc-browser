import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Sheets in the Arc style: New Folder, Delete Space and Rename Space. [07 §6] observed:
// a 450 pt wide card (radius ≈ 24), content from x 38, a Bold 17 title, Regular 14 body and field
// text, a 375.5 × 37.5 field (radius ≈ 6, white with a light gray outline), and at the lower right
// "Cancel [ESC]" (110 × 40) and the primary button (100 × 38.5), 28 pt from the right and 26.5 pt
// from the bottom. Sheets follow the Space's light / dark: #FAFBFF light, #171C30 dark.

/// A sheet button with its key cap ("ESC", "↵"). [07 §6] observed (gray rounded key caps).
struct ModalCardButton: View {
    enum Role { case cancel, primary, destructive }

    let title: String
    let keyCap: String
    let role: Role
    let palette: ThemePalette
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        let d = Metrics.Dialog.self
        let size = role == .cancel ? d.cancelButtonSize : d.primaryButtonSize
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).textStyle(Typography.dialogButton, ink: textInk)
                Text(keyCap)
                    .font(Typography.dialogKeyCap.font)
                    .foregroundStyle(textInk.swiftUI.opacity(0.6))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(textInk.swiftUI.opacity(0.10)))
            }
            .frame(width: CGFloat(size.width), height: CGFloat(size.height))
            .background(RoundedRectangle(cornerRadius: CGFloat(d.buttonCornerRadius), style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var fill: Color {
        switch role {
        case .cancel: return palette.dialogSecondaryButtonFill.swiftUI
        case .primary: return (isEnabled ? palette.dialogPrimaryButtonFill : palette.dialogPrimaryButtonDisabledFill).swiftUI
        case .destructive: return palette.dialogDestructiveFill.swiftUI
        }
    }

    private var textInk: RGBAColor {
        switch role {
        case .cancel: return palette.dialogInk
        case .primary: return isEnabled ? RGBAColor(hex: 0xFFFFFF) : RGBAColor(hex: 0x3D47F5, alpha: 0.6)
        case .destructive: return RGBAColor(hex: 0xFFFFFF)
        }
    }
}

/// The card body shared by the sheets: background, padding, the button row at the lower right.
struct ModalCard<Content: View>: View {
    let size: Size2D
    let palette: ThemePalette
    @ViewBuilder let content: () -> Content
    let buttons: () -> AnyView

    var body: some View {
        let d = Metrics.Dialog.self
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.leading, CGFloat(d.contentLeading))
                .padding(.trailing, CGFloat(d.contentTrailing))
                .frame(width: CGFloat(size.width), height: CGFloat(size.height), alignment: .topLeading)
            HStack(spacing: 10) { buttons() }
                .padding(.trailing, CGFloat(d.contentTrailing))
                .padding(.bottom, CGFloat(d.contentBottom))
        }
        .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        .background(palette.dialogBackground.swiftUI)
        .background(ClearSheetWindow())
        // Rounded card on a clear sheet window: nothing of the window shows at the corners.
        // [07 §12] observed (radius 26). B42.
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(d.cornerRadius), style: .continuous))
        .presentationBackground(.clear)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}

/// Makes the sheet window that hosts a `ModalCard` transparent, so only the rounded card shows.
/// The window's shadow follows the card's alpha. B42.
struct ClearSheetWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ProbeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ClearSheetWindow.makeClear(window)
            // AppKit finishes setting up the sheet after this view joins it: clear again once.
            DispatchQueue.main.async { [weak window] in
                MainActor.assumeIsolated { if let window { ClearSheetWindow.makeClear(window) } }
            }
        }
        // AppKit may restore the sheet's chrome when it presents or re-lays out the sheet.
        override func layout() {
            super.layout()
            if let window { ClearSheetWindow.makeClear(window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Clear, non-opaque, shadowed. Exposed for tests.
    @MainActor static func makeClear(_ window: NSWindow) {
        var changed = false
        if window.isOpaque { window.isOpaque = false; changed = true }
        if window.backgroundColor != .clear { window.backgroundColor = .clear; changed = true }
        if !window.hasShadow { window.hasShadow = true; changed = true }
        // A sheet's frame view draws its own material with a small corner radius behind the
        // content: hide it so only the card's radius 26 shows.
        if let frameView = window.contentView?.superview {
            for case let effect as NSVisualEffectView in frameView.subviews where !effect.isHidden {
                effect.isHidden = true
                changed = true
            }
            // The frame view draws the window frame (a light fill with the sheet's small system
            // corner radius) in a sublayer of its own: hide it. Matched by layer type name, as
            // AppKit gives it no public API; nothing happens when it is absent.
            for sub in frameView.layer?.sublayers ?? [] where !sub.isHidden && String(describing: type(of: sub)).contains("WindowFrameLayer") {
                sub.isHidden = true
                changed = true
            }
            // The window's root layer clips everything to its corner radius: give it the card's.
            var root = frameView.layer
            while let parent = root?.superlayer { root = parent }
            if let root, root.cornerRadius != CGFloat(Metrics.Dialog.cornerRadius) {
                root.cornerRadius = CGFloat(Metrics.Dialog.cornerRadius)
                root.cornerCurve = .continuous
                root.masksToBounds = true
                changed = true
            }
        }
        if changed { window.invalidateShadow() }
    }
}

/// The sheet text field: 375.5 × 37.5, radius ≈ 6, white with a light gray outline (dark: a
/// translucent white field, inferred), Regular 14 text. [07 §6] observed.
struct ModalCardTextField: View {
    let placeholder: String
    @Binding var text: String
    let palette: ThemePalette
    let identifier: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let d = Metrics.Dialog.self
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.dialogTextField.font)
            .foregroundStyle(palette.dialogInk.swiftUI)
            .padding(.horizontal, 12)
            .frame(width: CGFloat(d.textFieldSize.width), height: CGFloat(d.textFieldSize.height))
            .background(
                RoundedRectangle(cornerRadius: CGFloat(d.textFieldCornerRadius), style: .continuous)
                    .fill(palette.isDark ? Color.white.opacity(0.08) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat(d.textFieldCornerRadius), style: .continuous)
                    .strokeBorder(palette.dialogInk.swiftUI.opacity(0.15), lineWidth: 1)
            )
            .focused($focused)
            .onSubmit(onSubmit)
            .onAppear { focused = true }
            .accessibilityIdentifier(identifier)
    }
}

/// "New Folder…" modal. [06 §3] observed: title, one field ("What are you organizing?"), and
/// Cancel [ESC] / Create [↵]; [07 §6] observed geometry (450 × 222).
struct SidebarNewFolderSheet: View {
    @ObservedObject var viewModel: SidebarViewModel
    @State private var title = ""

    var body: some View {
        let palette = viewModel.palette
        let canCreate = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ModalCard(size: Metrics.Dialog.newFolderSize, palette: palette) {
            Text("New Folder…")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .padding(.top, ModalCardTokens.titleTop)
            ModalCardTextField(placeholder: "What are you organizing?", text: $title, palette: palette,
                               identifier: "openarc.newFolder.titleField", onSubmit: create)
                .padding(.top, ModalCardTokens.fieldGap)
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette) {
                    viewModel.isNewFolderSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Create", keyCap: "↵", role: .primary, palette: palette, isEnabled: canCreate, action: create)
                    .keyboardShortcut(.defaultAction)
            })
        }
    }

    private func create() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.createFolder(title: title, parent: viewModel.newFolderParentID)
    }
}

/// Delete Space confirmation. [06 §11] observed texts; [07 §6] observed geometry: 450 × 273, the
/// app icon 62 × 62 at (38, 38), the title at y 117, the body at y 154, the buttons at y 207;
/// "Delete" is red (#F43616).
struct DeleteSpaceSheet: View {
    let spaceName: String
    let palette: ThemePalette
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let d = Metrics.Dialog.self
        ModalCard(size: d.deleteSpaceSize, palette: palette) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: CGFloat(d.appIconSize), height: CGFloat(d.appIconSize))
                .padding(.top, CGFloat(d.appIconTop))
            Text("Delete your “\(spaceName)” Space?")
                .textStyle(Typography.dialogTitle, ink: palette.dialogInk)
                .lineLimit(1)
                .frame(height: CGFloat(Typography.dialogTitle.lineHeight))
                .padding(.top, CGFloat(d.deleteTitleTop - d.appIconTop - d.appIconSize))
            Text("This will archive all the tabs and folders inside it.")
                .textStyle(Typography.dialogBody, ink: palette.dialogInk)
                .padding(.top, CGFloat(d.deleteBodyTop - d.deleteTitleTop - Typography.dialogTitle.lineHeight))
        } buttons: {
            AnyView(Group {
                ModalCardButton(title: "Cancel", keyCap: "ESC", role: .cancel, palette: palette, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                ModalCardButton(title: "Delete", keyCap: "↵", role: .destructive, palette: palette, action: onDelete)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .accessibilityIdentifier("openarc.deleteSpace")
    }
}

/// Sheet layout values 07 did not measure. Each is our own; evidence `unknown`.
enum ModalCardTokens {
    /// Title top edge inside the New Folder card. unknown (the title x 38 is observed).
    static let titleTop: CGFloat = 36
    /// Gap between the title and the field. unknown.
    static let fieldGap: CGFloat = 18
}
