import SwiftUI
import OpenArcModel
import OpenArcDesign

// Library ▸ Easels list (plan B56). [06 §8] observed: a "Search Easels…" field, and with no Easel
// the "Out of ideas!" empty state. [06 §11] observed: an Easel card is about 60 pt square with an
// icon at the lower left and the title; a delete control was not in the context menu (maybe on
// hover). The grid, hover ✕ and click-to-open are inferred.

struct LibraryEaselsList: View {
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette

    var body: some View {
        let results = library.easelResults
        if results.isEmpty {
            if library.query(for: .easels).isEmpty, let empty = LibrarySection.easels.emptyState {
                LibraryEmptyStateView(state: empty, isBoosts: false, palette: palette)
            } else {
                Text("No Results")
                    .font(Typography.libraryRowDetail.font)
                    .foregroundStyle(palette.secondaryText.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .accessibilityIdentifier("openarc.library.easels.noResults")
            }
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: LibraryEaselCard.side, maximum: LibraryEaselCard.side * 1.6), spacing: 10)], spacing: 10) {
                    ForEach(results, id: \.id) { easel in
                        LibraryEaselCard(easel: easel, palette: palette) {
                            library.openEasel(easel.id)
                        } onDelete: {
                            library.deleteEasel(easel.id)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("openarc.library.easels")
        }
    }
}

struct LibraryEaselCard: View {
    /// [06 §11] observed: about 60 pt square.
    static let side: CGFloat = 60

    let easel: Easel
    let palette: ThemePalette
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        let text = palette.primaryText.swiftUI
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                Image(systemName: EaselIcon.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .padding(8)
                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.7))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.white).shadow(color: .black.opacity(0.2), radius: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete Easel")
                    .accessibilityIdentifier("openarc.library.easel.delete")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(easel.displayTitle)
                .font(Typography.libraryRowTitle.font)
                .foregroundStyle(text)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(easel.displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("openarc.library.easel.\(easel.id.uuidString)")
    }
}

/// The Easel icon of sidebar rows and Library cards (our own symbol). [06 §4] observed that Easel
/// rows have an Easel icon.
enum EaselIcon {
    static let symbol = "scribble.variable"
}

/// The URL box of an Easel: a "Share" button with a lock instead of a domain. [06 §4, §9]
/// observed. Inert: sharing and collaboration are out of scope (B56).
struct EaselShareURLBox: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        let palette = viewModel.palette
        let s = Metrics.Sidebar.self
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button {} label: {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                    Text("Share").font(Typography.addressPlaceholder.font)
                }
                .foregroundStyle(palette.ink(\.addressText).swiftUI)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(palette.controlFill.swiftUI))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Sharing is not available")
            .accessibilityLabel("Share")
            .accessibilityIdentifier("openarc.sidebar.urlBox.easelShare")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(s.addressFieldCornerRadius), style: .continuous)
                .fill(palette.controlFill.swiftUI.opacity(0.5))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.urlBox")
    }
}
