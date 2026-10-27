import SwiftUI
import OpenArcModel

/// Geometry of the Air Traffic Control sheet. [06 §25.2] observed unless noted.
enum AirTrafficControlTokens {
    static let sheetSize = CGSize(width: 508, height: 500)
    static let listWidth: CGFloat = 460
    static let matchMenuWidth: CGFloat = 110
    static let patternFieldWidth: CGFloat = 210
    static let targetMenuWidth: CGFloat = 240
    static let newRouteButtonSize = CGSize(width: 122, height: 28)
    static let closeButtonSize: CGFloat = 32
    static let removeButtonSize: CGFloat = 13
    /// Line 1 of one route to line 1 of the next: about 76.
    static let routePitch: CGFloat = 76
    /// Placeholder of the URL field: Arc shows "arc.net"; ours names an example domain (inferred).
    static let patternPlaceholder = "example.com"
}

/// The sheet behind Settings ▸ Links ▸ "Air Traffic Control…". [06 §25.2] observed: title,
/// "New Route" and ✕ on top; the route list; "Default" at the bottom. Changes save at once.
struct AirTrafficControlSheet: View {
    @StateObject private var model: AirTrafficControlModel
    var onClose: () -> Void

    init(model: @autoclosure @escaping () -> AirTrafficControlModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model())
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            routeList
            Divider()
            defaultRow
        }
        .frame(width: AirTrafficControlTokens.sheetSize.width, height: AirTrafficControlTokens.sheetSize.height)
        .accessibilityIdentifier("openarc.airTrafficControl")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Air Traffic Control").font(.system(size: 13, weight: .bold))
            Spacer()
            Button("New Route") { model.addRoute() }
                .frame(minWidth: AirTrafficControlTokens.newRouteButtonSize.width)
                .controlSize(.large)
                .accessibilityIdentifier("openarc.airTrafficControl.newRoute")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: AirTrafficControlTokens.closeButtonSize, height: AirTrafficControlTokens.closeButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.routes) { route in
                    routeRow(route)
                        .frame(height: AirTrafficControlTokens.routePitch, alignment: .center)
                }
            }
            .frame(width: AirTrafficControlTokens.listWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if model.routes.isEmpty {
                // Our empty state (inferred: the spec shows only a list with routes).
                Text("Add a route to choose where links from other apps open.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func routeRow(_ route: AirTrafficRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("URL", systemImage: "link").labelStyle(.titleAndIcon)
                Picker("", selection: Binding(get: { route.match }, set: { model.setMatch($0, for: route.id) })) {
                    ForEach(AirTrafficMatch.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: AirTrafficControlTokens.matchMenuWidth)
                TextField(AirTrafficControlTokens.patternPlaceholder, text: Binding(
                    get: { route.pattern }, set: { model.setPattern($0, for: route.id) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: AirTrafficControlTokens.patternFieldWidth)
                Spacer(minLength: 0)
                Button { model.removeRoute(route.id) } label: {
                    Image(systemName: "minus.circle.fill")
                        .resizable()
                        .frame(width: AirTrafficControlTokens.removeButtonSize, height: AirTrafficControlTokens.removeButtonSize)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Route")
            }
            HStack(spacing: 8) {
                Text("↳ Open in")
                targetMenu(selection: route.target, routeID: route.id)
            }
        }
    }

    private var defaultRow: some View {
        HStack(spacing: 8) {
            Text("Default")
            Spacer()
            targetMenu(selection: model.defaultTarget, routeID: nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// The target picker of a route, or of the Default row when `routeID` is nil.
    private func targetMenu(selection: AirTrafficTarget, routeID: AirTrafficRoute.ID?) -> some View {
        let model = model
        return Picker("", selection: Binding(get: { selection }, set: { target in
            if let routeID { model.setTarget(target, for: routeID) } else { model.setDefaultTarget(target) }
        })) {
            ForEach(model.options(including: selection)) { option in
                Text(option.title).tag(option.target)
            }
        }
        .labelsHidden()
        .frame(width: AirTrafficControlTokens.targetMenuWidth)
    }
}
