import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The Easel canvas in the web panel (plan B56). [06 §9] observed: a full-page canvas with a centered
// ≈ 24 pt bold "Untitled Easel" title at the top, scroll bars on both axes, a floating toolbar at the
// lower left (select — highlighted by default —, image, text "A", circle, square, arrow, pen, and a
// stacked-squares-with-plus "capture / add" icon) and an "add collaborator" (person +) button at the
// lower right. Sizes, colors and the editing gestures are inferred (`Metrics.Easel`, `EaselTokens`).

struct EaselCanvasView: View {
    @ObservedObject var model: EaselCanvasModel
    let size: CGSize

    @State private var scrollOrigin: CGPoint = .zero
    @FocusState private var canvasFocused: Bool

    var body: some View {
        let dark = model.colorScheme == .dark
        let background = dark ? EaselTokens.canvasBackgroundDark : EaselTokens.canvasBackgroundLight
        let elements = model.renderedElements
        let canvas = EaselGeometry.canvasSize(for: elements, viewport: Size2D(width: size.width, height: size.height))
        ZStack(alignment: .bottomLeading) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    pointerLayer(width: canvas.width, height: canvas.height)
                    ForEach(elements, id: \.id) { element in
                        EaselElementView(element: element, dark: dark)
                            .allowsHitTesting(false)
                    }
                    selectionOverlay(elements: elements)
                        .allowsHitTesting(false)
                    if let editingID = model.editingTextID, let element = elements.first(where: { $0.id == editingID }) {
                        EaselTextEditor(model: model, element: element, dark: dark)
                    }
                    if let easel = model.easel {
                        EaselTitleField(model: model, easel: easel, ink: dark ? EaselTokens.inkDark : EaselTokens.ink)
                            .frame(width: CGFloat(Metrics.Easel.titleMaxWidth))
                            .position(x: size.width / 2, y: CGFloat(Metrics.Easel.titleTopInset) + CGFloat(Typography.easelTitle.lineHeight) / 2)
                    }
                }
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: EaselScrollOriginKey.self, value: geo.frame(in: .named(EaselScrollOriginKey.space)).origin)
                })
            }
            .coordinateSpace(name: EaselScrollOriginKey.space)
            .onPreferenceChange(EaselScrollOriginKey.self) { scrollOrigin = $0 }

            EaselToolbar(model: model)
                .padding(CGFloat(Metrics.Easel.toolbarInset))
            HStack {
                Spacer()
                EaselCollaboratorButton(model: model)
            }
            .padding(CGFloat(Metrics.Easel.toolbarInset))
        }
        .frame(width: size.width, height: size.height)
        .background(background.swiftUI)
        .environment(\.colorScheme, dark ? .dark : .light)
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onDeleteCommand { model.deleteSelection() }
        .onExitCommand { model.cancel() }
        .onPasteCommand(of: [.image, .fileURL, .plainText]) { _ in model.paste() }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        .onAppear {
            model.pickImage = { EaselImageEncoder.pickImageFile() }
            model.readPasteboard = { EaselImageEncoder.readPasteboard() }
        }
        .onChange(of: scrollOrigin) { _, _ in installVisibleRect() }
        .onChange(of: size) { _, _ in installVisibleRect() }
        .onAppear { installVisibleRect() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.easel")
    }

    private func installVisibleRect() {
        let origin = scrollOrigin, size = self.size
        model.visibleRect = { EaselRect(x: -origin.x, y: -origin.y, width: size.width, height: size.height) }
    }

    /// The layer under everything that takes every pointer event (local = canvas coordinates).
    private func pointerLayer(width: Double, height: Double) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let p = EaselPoint(x: value.location.x, y: value.location.y)
                        if value.translation == .zero, !isDragging {
                            canvasFocused = true
                            let event = NSApp.currentEvent
                            model.pointerDown(
                                at: EaselPoint(x: value.startLocation.x, y: value.startLocation.y),
                                extend: event?.modifierFlags.contains(.shift) ?? false,
                                clickCount: event?.clickCount ?? 1
                            )
                            isDragging = true
                        } else {
                            model.pointerDragged(to: p)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        model.pointerUp(at: EaselPoint(x: value.location.x, y: value.location.y))
                    }
            )
            .accessibilityIdentifier("openarc.easel.canvas")
    }

    @State private var isDragging = false

    @ViewBuilder
    private func selectionOverlay(elements: [EaselElement]) -> some View {
        let selected = elements.filter { model.selection.contains($0.id) && $0.id != model.editingTextID }
        let color = EaselTokens.selectionColor.swiftUI
        let handle = CGFloat(Metrics.Easel.handleSize)
        ForEach(selected, id: \.id) { element in
            let f = element.frame
            Rectangle()
                .stroke(color, lineWidth: CGFloat(Metrics.Easel.selectionOutlineWidth))
                .frame(width: f.width, height: f.height)
                .offset(x: f.x, y: f.y)
            if selected.count == 1 {
                ForEach(EaselHandle.allCases, id: \.self) { h in
                    let p = h.point(on: f)
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(color, lineWidth: 1))
                        .frame(width: handle, height: handle)
                        .offset(x: p.x - handle / 2, y: p.y - handle / 2)
                }
            }
        }
    }
}

private struct EaselScrollOriginKey: PreferenceKey {
    static let space = "openarc.easel.scroll"
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

// MARK: - Elements

/// One element, drawn at its frame in canvas coordinates.
struct EaselElementView: View {
    let element: EaselElement
    let dark: Bool

    var body: some View {
        let f = element.frame
        let ink = Self.ink(element.style.strokeColor, dark: dark)
        switch element.content {
        case .text(let string):
            Text(string)
                .font(.system(size: CGFloat(element.style.fontSize)))
                .foregroundStyle(ink)
                .frame(width: f.width, height: f.height, alignment: .topLeading)
                .offset(x: f.x, y: f.y)
        case .image(let image):
            EaselImageView(image: image)
                .frame(width: f.width, height: f.height)
                .offset(x: f.x, y: f.y)
        default:
            let pad = element.style.strokeWidth + EaselTokens.arrowHeadLength
            Canvas { context, _ in
                let path = EaselShapePath.path(for: element, origin: CGPoint(x: f.x - pad, y: f.y - pad))
                if let fill = element.style.fillColor, element.content.kind == .circle || element.content.kind == .rectangle {
                    context.fill(path, with: .color(fill.swiftUI))
                }
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: element.style.strokeWidth, lineCap: .round, lineJoin: .round))
            }
            .frame(width: f.width + 2 * pad, height: f.height + 2 * pad)
            .offset(x: f.x - pad, y: f.y - pad)
        }
    }

    /// The default near-black ink turns light on a dark canvas; picked colors stay. inferred.
    static func ink(_ color: RGBAColor, dark: Bool) -> Color {
        (dark && color == EaselTokens.ink ? EaselTokens.inkDark : color).swiftUI
    }
}

/// Paths of the drawn kinds, in a coordinate space whose origin is `origin` (canvas coordinates).
enum EaselShapePath {
    static func path(for element: EaselElement, origin: CGPoint) -> Path {
        let f = element.frame
        let rect = CGRect(x: f.x - origin.x, y: f.y - origin.y, width: f.width, height: f.height)
        func point(_ p: EaselPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        var path = Path()
        switch element.content {
        case .circle:
            path.addEllipse(in: rect)
        case .rectangle:
            path.addRect(rect)
        case .arrow(let start, let end):
            let a = point(start), b = point(end)
            path.move(to: a)
            path.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let spread = EaselTokens.arrowHeadHalfAngle * .pi / 180
            let length = EaselTokens.arrowHeadLength
            for side in [-1.0, 1.0] {
                path.move(to: b)
                path.addLine(to: CGPoint(x: b.x - length * cos(angle + side * spread), y: b.y - length * sin(angle + side * spread)))
            }
        case .pen(let points):
            guard let first = points.first else { break }
            path.move(to: point(first))
            if points.count == 1 {
                path.addLine(to: point(first))
            }
            for p in points.dropFirst() { path.addLine(to: point(p)) }
        case .text, .image:
            break
        }
        return path
    }
}

/// An inline image. Decoded once per image value.
struct EaselImageView: View {
    let image: EaselImage

    var body: some View {
        if let nsImage = EaselImageCache.shared.image(for: image) {
            Image(nsImage: nsImage).resizable().interpolation(.high)
        } else {
            Rectangle().fill(Color.gray.opacity(0.2))
        }
    }
}

/// Decoded Easel images by their bytes, so redraws do not decode again.
@MainActor
final class EaselImageCache {
    static let shared = EaselImageCache()
    private var images: [Data: NSImage] = [:]

    func image(for image: EaselImage) -> NSImage? {
        if let cached = images[image.data] { return cached }
        guard let decoded = NSImage(data: image.data) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[image.data] = decoded
        return decoded
    }
}

// MARK: - Text and title

/// Height of laid-out text in a box `width` wide.
enum EaselTextMetrics {
    static func height(_ string: String, fontSize: Double, width: Double) -> Double {
        let text = string.isEmpty ? " " : string
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        return ceil(rect.height) + 4
    }
}

/// The text box being edited, over its element.
struct EaselTextEditor: View {
    @ObservedObject var model: EaselCanvasModel
    let element: EaselElement
    let dark: Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let f = element.frame
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(element.style.fontSize)))
            .foregroundStyle(EaselElementView.ink(element.style.strokeColor, dark: dark))
            .focused($focused)
            .frame(width: f.width, alignment: .topLeading)
            .frame(minHeight: f.height, alignment: .topLeading)
            .overlay(Rectangle().stroke(EaselTokens.selectionColor.swiftUI.opacity(0.6), lineWidth: 1))
            .offset(x: f.x, y: f.y)
            .onSubmit(commit)
            .onExitCommand(perform: commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear {
                if case .text(let string) = element.content { text = string }
                // The click that made the box gave the canvas focus in the same update; take it
                // on the next turn of the run loop, or the keys would go to the canvas.
                DispatchQueue.main.async { focused = true }
            }
            .accessibilityIdentifier("openarc.easel.textEditor")
    }

    private func commit() {
        guard model.editingTextID == element.id else { return }
        model.commitText(element.id, string: text, height: EaselTextMetrics.height(text, fontSize: element.style.fontSize, width: element.frame.width))
    }
}

/// The canvas title: "Untitled Easel", editable in place. [06 §9] observed.
struct EaselTitleField: View {
    @ObservedObject var model: EaselCanvasModel
    let easel: Easel
    let ink: RGBAColor

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(Easel.defaultTitle, text: $text)
            .textFieldStyle(.plain)
            .font(Typography.easelTitle.font)
            .multilineTextAlignment(.center)
            .foregroundStyle(ink.swiftUI)
            .focused($focused)
            .onSubmit { model.renameTitle(text) }
            .onChange(of: focused) { _, isFocused in if !isFocused { model.renameTitle(text) } }
            .onChange(of: easel.title) { _, title in if !focused { text = title } }
            .onAppear { text = easel.title }
            .onChange(of: easel.id) { _, _ in text = easel.title }
            .accessibilityIdentifier("openarc.easel.title")
    }
}

// MARK: - Toolbar

/// The floating toolbar at the lower left. [06 §9] observed order and icons; drawing is ours.
struct EaselToolbar: View {
    @ObservedObject var model: EaselCanvasModel

    var body: some View {
        let m = Metrics.Easel.self
        HStack(spacing: CGFloat(m.toolbarButtonSpacing)) {
            ForEach(EaselCanvasModel.Tool.allCases, id: \.self) { tool in
                Button { model.selectTool(tool) } label: {
                    Image(systemName: Self.symbol(tool))
                        .font(.system(size: CGFloat(m.toolbarIconSize), weight: .medium))
                        .foregroundStyle(EaselTokens.toolbarIcon.swiftUI)
                        .frame(width: CGFloat(m.toolbarButtonSize), height: CGFloat(m.toolbarButtonSize))
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat(m.toolbarCornerRadius) - CGFloat(m.toolbarPadding), style: .continuous)
                                .fill(model.tool == tool ? EaselTokens.toolbarSelectedFill.swiftUI : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.label(tool))
                .accessibilityLabel(Self.label(tool))
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                .accessibilityIdentifier("openarc.easel.tool.\(tool.rawValue)")
            }
        }
        .padding(CGFloat(m.toolbarPadding))
        .background(
            RoundedRectangle(cornerRadius: CGFloat(m.toolbarCornerRadius), style: .continuous)
                .fill(EaselTokens.toolbarBackground.swiftUI)
                .shadow(color: .black.opacity(EaselTokens.toolbarShadowOpacity), radius: 8, y: 2)
        )
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.easel.toolbar")
    }

    /// Our own SF Symbols for the observed icons.
    static func symbol(_ tool: EaselCanvasModel.Tool) -> String {
        switch tool {
        case .select: return "cursorarrow"
        case .image: return "photo"
        case .text: return "textformat"
        case .circle: return "circle"
        case .rectangle: return "square"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .capture: return "plus.square.on.square"
        }
    }

    static func label(_ tool: EaselCanvasModel.Tool) -> String {
        switch tool {
        case .select: return "Select"
        case .image: return "Image"
        case .text: return "Text"
        case .circle: return "Circle"
        case .rectangle: return "Rectangle"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        case .capture: return "Capture"
        }
    }
}

/// "Add collaborator" at the lower right. [06 §9] observed. Inert: collaboration is out of scope.
struct EaselCollaboratorButton: View {
    @ObservedObject var model: EaselCanvasModel

    var body: some View {
        let side = CGFloat(Metrics.Easel.collaboratorButtonSize)
        Button { model.inertCollaborationAction() } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: CGFloat(Metrics.Easel.toolbarIconSize), weight: .medium))
                .foregroundStyle(EaselTokens.toolbarIcon.swiftUI)
                .frame(width: side, height: side)
                .background(Circle().fill(EaselTokens.toolbarBackground.swiftUI)
                    .shadow(color: .black.opacity(EaselTokens.toolbarShadowOpacity), radius: 8, y: 2))
        }
        .buttonStyle(.plain)
        .help("Add Collaborator")
        .accessibilityLabel("Add Collaborator")
        .accessibilityIdentifier("openarc.easel.collaborators")
    }
}

// MARK: - Web panel content

/// The single web panel's content: the Easel canvas when the selected tab is an Easel's row, else
/// the engine page. B56.
struct EaselOrWebPanel: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    let size: CGSize
    let palette: ThemePalette

    var body: some View {
        if sidebar.selectedEaselID != nil {
            EaselCanvasView(model: model.easelCanvas, size: size)
        } else {
            WebPanel(tab: model.selectedLiveTab, findBar: model.findBarHost, background: palette.webPanelBackground, backgroundGradient: palette.webPanelBackgroundGradient,
                     crashed: model.crashedPageState(for: sidebar.selectedTabID))
        }
    }
}
