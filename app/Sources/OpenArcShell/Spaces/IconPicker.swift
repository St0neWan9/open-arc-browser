import SwiftUI
import OpenArcModel
import OpenArcDesign

// The icon picker: an Emoji | Icon switch, a trash button that clears the icon, and an 8-column
// grid. Layout observed on 2× Arc captures (B172): the Icon page opens first and is one color; the
// Emoji page has a search field, the system's color emoji and a category bar. The symbols are SF
// Symbols of our choosing, close to the subjects Arc offers.

enum IconPickerTokens {
    /// The bubble is square. observed.
    static let size: CGFloat = 272
    static let cornerRadius: CGFloat = 20
    static let columns = 8
    /// Cell pitch and cell size. observed.
    static let pitch: CGFloat = 31
    static let cell: CGFloat = 30
    static let cellRadius: CGFloat = 5
    /// The Emoji page's rows are taller. observed.
    static let emojiRowPitch: CGFloat = 33
    static let emojiSize: CGFloat = 20
    static let symbolSize: CGFloat = 15
    static let switchSize = CGSize(width: 106, height: 24)
    static let switchTop: CGFloat = 15
    static let gridTop: CGFloat = 48
    static let searchHeight: CGFloat = 25
    static let categoryBarHeight: CGFloat = 44
    /// Selected half of the switch and the picked cell. observed (#919191, ≈ 10 % black).
    static let selectedSwitchFill = RGBAColor(hex: 0x919191)
    static let trackOpacity: Double = 0.08
    static let pickedCellOpacity: Double = 0.1
    static let symbolInkOpacity: Double = 0.55
}

/// What the icon page offers. A symbol name is stored as the icon string (`Space.icon`: "an emoji
/// or an icon name").
enum IconPickerCatalog {
    static let symbols: [String] = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
        "lightbulb.fill", "square.on.circle.fill", "square.grid.2x2.fill", "square.grid.3x3.fill",
        "square.stack.3d.up.fill", "cylinder.split.1x2.fill", "archivebox.fill", "square.fill.on.square.fill",
        "folder.fill", "tray.full.fill", "calendar", "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill", "ellipsis.bubble.fill",
        "person.2.fill", "apple.terminal.fill", "wrench.and.screwdriver.fill", "square.fill", "oval.portrait.fill", "circle.fill", "moon.fill", "sun.max.fill",
        "globe.americas.fill", "leaf.fill", "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill", "bed.double.fill", "fork.knife",
        "dumbbell.fill", "airplane", "music.note", "paintpalette.fill", "video.fill", "bandage.fill", "chevron.left.forwardslash.chevron.right", "baseball.fill",
        "cloud", "map.fill", "flame.fill", "birthday.cake.fill", "theatermasks.fill", "scroll.fill", "hand.thumbsup.fill", "tram.fill",
    ]

    struct EmojiCategory: Identifiable {
        var id: String { symbol }
        /// Outline symbol in the category bar.
        var symbol: String
        var emoji: [String]
    }

    private static func split(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

    static let emoji: [EmojiCategory] = [
        EmojiCategory(symbol: "face.smiling", emoji: split("😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 🫠 😉 😊 😇 🥰 😍 🤩 😘 😗 ☺️ 😚 😙 🥲 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🫢 🫣 🤫 🤔 🫡 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 🥸 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 👻 👽 🤖 💩 👋 👍 👎 👏 🙌 🙏 💪 🧠 👀")),
        EmojiCategory(symbol: "sun.max", emoji: split("🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦆 🦅 🦉 🦇 🐺 🐝 🦋 🐌 🐞 🐢 🐍 🐙 🦀 🐠 🐬 🐳 🦈 🐘 🦒 🐎 🌵 🌲 🌳 🌴 🌱 🌿 🍀 🍁 🍂 🌷 🌹 🌻 🌸 🌞 🌝 🌙 ⭐️ 🌟 ✨ ⚡️ 🔥 🌈 ☀️ ☁️ ❄️ 💧 🌊")),
        EmojiCategory(symbol: "cup.and.saucer", emoji: split("🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🥦 🥕 🌽 🌶️ 🥔 🍞 🥐 🧀 🥚 🍳 🥓 🍔 🍟 🍕 🌭 🥪 🌮 🌯 🍝 🍜 🍣 🍱 🍤 🍚 🍦 🍩 🍪 🎂 🍰 🍫 🍬 🍿 ☕️ 🍵 🧃 🍺 🍷 🍸")),
        EmojiCategory(symbol: "medal", emoji: split("⚽️ 🏀 🏈 ⚾️ 🎾 🏐 🏉 🎱 🏓 🏸 🥊 🥋 ⛳️ 🎣 🎿 🏂 🏋️ 🚴 🏊 🧘 🏆 🥇 🥈 🥉 🎖️ 🎫 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 🎯 🎮 🧩")),
        EmojiCategory(symbol: "box.truck", emoji: split("🚗 🚕 🚌 🏎️ 🚓 🚑 🚒 🚚 🚜 🚲 🛵 🏍️ 🚂 🚆 🚇 🚊 ✈️ 🚀 🛸 🚁 ⛵️ 🚢 ⚓️ 🗺️ 🗿 🗽 🗼 🏰 🏯 🏟️ 🎡 🎢 ⛲️ ⛱️ 🏖️ 🏝️ ⛰️ 🏔️ 🗻 🏕️ 🏠 🏡 🏢 🏬 🏦 🏥 🏫 ⛪️ 🌉 🌃")),
        EmojiCategory(symbol: "gift", emoji: split("⌚️ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💽 💾 💿 📷 📹 🎥 📺 📻 🎙️ ⏰ 🔋 🔌 💡 🔦 🕯️ 💸 💵 💰 💳 💎 ⚖️ 🧰 🔧 🔨 ⚒️ 🛠️ ⚙️ 🔩 🧲 🔫 💣 🧪 🔬 🔭 💊 🩹 🚪 🛏️ 🛒 🎁 🎈 🎉 📦 📫 📮 📜 📄 📊 📈 📉 📅 📁 📂 📌 📎 📏 ✂️ 📝 ✏️ 🔍 🔒 🔑 📚 📖 📰")),
        EmojiCategory(symbol: "heart", emoji: split("❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💖 💯 💢 💥 💫 💬 💭 ♻️ ⚠️ 🚫 ⛔️ ✅ ❌ ❓ ❗️ ➕ ➖ ➗ ✖️ ♾️ 🔔 🔕 🎵 🎶 🔴 🟠 🟡 🟢 🔵 🟣 ⚫️ ⚪️ 🟥 🟧 🟨 🟩 🟦 🟪")),
        EmojiCategory(symbol: "flag", emoji: split("🏁 🚩 🏴 🏳️ 🏳️‍🌈 🏴‍☠️ 🇨🇳 🇺🇸 🇬🇧 🇯🇵 🇰🇷 🇩🇪 🇫🇷 🇮🇹 🇪🇸 🇨🇦 🇦🇺 🇧🇷 🇮🇳 🇷🇺 🇸🇬 🇭🇰 🇹🇼 🇪🇺 🇺🇳")),
    ]

    /// Emoji whose Unicode name holds `query`, across the categories.
    static func search(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return [] }
        return emoji.flatMap(\.emoji).filter { candidate in
            candidate.unicodeScalars.contains { $0.properties.name?.contains(needle) == true }
        }
    }
}

/// The picker's content, in a square of `IconPickerTokens.size`.
struct SpaceIconGrid: View {
    enum Page: Hashable { case emoji, icon }

    /// Enables the trash button. Only useful when an icon is set.
    let showsReset: Bool
    /// The current icon: marked in the grid.
    var selected: String? = nil
    /// Called with the chosen icon; nil resets to the default.
    let onChoose: (String?) -> Void

    @State private var page: Page = .icon
    @State private var query = ""
    @State private var category = IconPickerCatalog.emoji[0].id

    private typealias T = IconPickerTokens
    private var columns: [GridItem] { Array(repeating: GridItem(.fixed(T.pitch), spacing: 0), count: T.columns) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, T.switchTop)
            switch page {
            case .icon: iconPage
            case .emoji: emojiPage
            }
        }
        .frame(width: T.size, height: T.size, alignment: .top)
        .accessibilityIdentifier("openarc.space.iconGrid")
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                switchHalf("Emoji", .emoji)
                switchHalf("Icon", .icon)
            }
            .frame(width: T.switchSize.width, height: T.switchSize.height)
            .background(RoundedRectangle(cornerRadius: T.cellRadius, style: .continuous).fill(Color.primary.opacity(T.trackOpacity)))
            Button { onChoose(nil) } label: {
                Image(systemName: "trash").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(!showsReset)
            .accessibilityLabel("Use Default Icon")
        }
    }

    private func switchHalf(_ title: String, _ value: Page) -> some View {
        let isOn = page == value
        return Text(title)
            .font(.system(size: 13))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: T.cellRadius, style: .continuous)
                .fill(isOn ? T.selectedSwitchFill.swiftUI : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { page = value }
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var iconPage: some View {
        LazyVGrid(columns: columns, spacing: T.pitch - T.cell) {
            ForEach(IconPickerCatalog.symbols, id: \.self) { name in
                Button { onChoose(name) } label: {
                    Image(systemName: name)
                        .font(.system(size: T.symbolSize))
                        .foregroundStyle(Color.primary.opacity(T.symbolInkOpacity))
                        .frame(width: T.cell, height: T.cell)
                        .background(RoundedRectangle(cornerRadius: T.cellRadius, style: .continuous)
                            .fill(Color.primary.opacity(name == selected ? T.pickedCellOpacity : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
        .padding(.top, T.gridTop - T.switchTop - T.switchSize.height)
    }

    private var emojiPage: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.top, 9)
            if query.isEmpty {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(IconPickerCatalog.emoji) { group in
                                emojiGrid(group.emoji).id(group.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    Divider()
                    categoryBar(reader)
                }
            } else {
                ScrollView(.vertical) { emojiGrid(IconPickerCatalog.search(query)) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 8)
        .frame(width: CGFloat(T.columns) * T.pitch + 4, height: T.searchHeight)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(T.trackOpacity), lineWidth: 1))
    }

    private func emojiGrid(_ emoji: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(emoji, id: \.self) { item in
                Button { onChoose(item) } label: {
                    Text(item)
                        .font(.system(size: T.emojiSize))
                        .frame(width: T.pitch, height: T.emojiRowPitch)
                        .background(RoundedRectangle(cornerRadius: T.cellRadius, style: .continuous)
                            .fill(Color.primary.opacity(item == selected ? T.pickedCellOpacity : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func categoryBar(_ reader: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(IconPickerCatalog.emoji) { group in
                Button {
                    category = group.id
                    reader.scrollTo(group.id, anchor: .top)
                } label: {
                    Image(systemName: group.symbol)
                        .font(.system(size: T.symbolSize))
                        .foregroundStyle(Color.primary.opacity(category == group.id ? 1 : T.symbolInkOpacity))
                        .frame(width: T.pitch, height: T.categoryBarHeight - 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: T.categoryBarHeight - 8)
    }
}

/// Change Space Icon… in its bubble: follows the workspace, so the mark moves as icons are tried.
struct SpaceIconPickerBubble: View {
    @ObservedObject var flow: SpaceFlowModel
    @ObservedObject var sidebar: SidebarViewModel
    let palette: ThemePalette

    var body: some View {
        let icon = flow.iconPickerSpaceID.flatMap { sidebar.workspace.spaces[$0]?.icon }
        SpaceIconGrid(showsReset: icon != nil, selected: icon) { flow.applyIcon($0) }
            .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}
