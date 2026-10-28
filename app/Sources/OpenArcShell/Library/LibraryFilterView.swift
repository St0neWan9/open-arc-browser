import SwiftUI
import OpenArcModel
import OpenArcDesign

// The Library's Filter panel (plan B94). Behavior and texts: LibraryFilter.swift. [06 §8] Filter
// (E24), observed: a title with "Done" on its right takes the search field's place, and capsule
// buttons, grouped under small labels, sit above the list.

struct LibraryFilterPanel: View {
    @ObservedObject var library: LibraryModel
    let title: String
    let palette: ThemePalette
    @Environment(\.windowSurface) private var surface

    var body: some View {
        let text = palette.primaryText.swiftUI
        VStack(alignment: .leading, spacing: LibraryLocalTokens.filterGroupSpacing) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typography.librarySearch.font.weight(.semibold))
                    .foregroundStyle(text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(LibraryTexts.filterDone) { library.closeFilterPanel() }
                    .buttonStyle(.plain)
                    .font(Typography.libraryRowTitle.font.weight(.medium))
                    .foregroundStyle(text.opacity(0.8))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("openarc.library.filter.done")
            }
            .padding(.horizontal, 4)
            .frame(height: LibraryLocalTokens.searchFieldHeight)
            .accessibilityIdentifier("openarc.library.filter.title")

            ForEach(library.filterGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .textStyle(Typography.libraryGroupHeader, ink: palette.chromeInk)
                    LibraryChipFlow(spacing: LibraryLocalTokens.filterChipSpacing) {
                        ForEach(group.chips) { chip in
                            chipView(chip, text: text)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(group.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.filter.panel")
    }

    private func chipView(_ chip: LibraryFilterChip, text: Color) -> some View {
        let isOn = library.filterSelection.options.contains(chip.option)
        // Selected: a black layer over the control fill, which darkens it by the shade factor on
        // opaque and see-through windows alike (the rail's rule, B64).
        let fill = palette.windowFills(on: surface).controlFill.swiftUI
        let darken = Color.black.opacity(isOn ? 1 - LibraryLocalTokens.filterChipSelectedShade : 0)
        return Text(chip.title)
            .font(Typography.libraryRowDetail.font.weight(isOn ? .semibold : .regular))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, LibraryLocalTokens.filterChipHorizontalPadding)
            .frame(height: LibraryLocalTokens.filterChipHeight)
            .background(Capsule().fill(fill).overlay(Capsule().fill(darken)))
            .contentShape(Capsule())
            .onTapGesture { library.toggleFilter(chip.option) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("openarc.library.filter.chip")
    }
}

/// Lays chips out left to right and wraps to a new line when the row is full.
struct LibraryChipFlow: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
