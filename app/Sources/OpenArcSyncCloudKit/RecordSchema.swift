import CloudKit
import OpenArcModel
import OpenArcSyncAPI

// # CloudKit record schema
//
// Every CloudKit field key below is PERSISTED SCHEMA. Never rename a key, never move a key to a
// different field group, and never flip its encrypted/plain choice: CloudKit fixes a field's
// encryption the first time the field is saved, so a change needs a new key name plus a migration.
//
// Layout rules:
// - One CloudKit field per model value, prefixed with the name of its field group
//   (`<group>_<name>`). The per-group timestamps travel as `groupTime_<group>`, so the receiving
//   device can run `ConflictPolicy` group by group and last-writer-wins per group is preserved.
// - Sync metadata uses the `meta_` prefix and belongs to no group.
// - Every send writes every key, including explicit nils. A record rebuilt from archived system
//   fields carries no values, and CloudKit uploads only changed keys, so an omitted key would keep
//   a stale server value.
//
// Encryption choice (plan D10): what the user made or chose goes into `encryptedValues`, which
// CloudKit encrypts with keys from the user's iCloud Keychain: titles, URLs, favicon URLs, names,
// icons, folder paths, a theme's appearance and colors, and everything an easel element draws
// (content, frame, style). Plain, each with its reason:
// - ids and references (random UUIDs), sort keys, the tab location kind, a folder's expanded
//   flag, an archive item's reason and a split's pane tree (tab ids and fractions): tree
//   structure only, no content; the record names ("Tab/<UUID>") are plain anyway, and a plain
//   tree keeps sync problems diagnosable in the CloudKit Console;
// - timestamps (`activity_lastActiveAt`, `content_archivedAt`, `meta_*At`, `groupTime_*`):
//   CloudKit's own creation and modification dates, which no client can hide, give the server
//   the same times, so encrypting them would hide nothing;
// - the sync metadata (`meta_*`), including the writer's schema version (D11), which the store
//   reads before it can decode a record and the Console must show for mixed-version setups.
// No field needs a query index: CKSyncEngine and the zone poll fetch by change token. The
// encrypted groups match `SyncRecordType.encryptedFieldGroups`. docs/arc-spec/03-settings.md
// §账号卡: "Arc Sync is end-to-end encrypted" (observed); Arc encrypting its whole sidebar payload
// is inferred (analysis). The per-field split is ours.
//
// Migration (D10): a field first deployed plain cannot become encrypted, so it gets a new key
// (`<old key>Enc`) and keeps the old one as its `legacyKey`. Every write sets the new key and
// clears the old one (the plain copy leaves the server on the record's next save). Reading prefers
// the old key when it holds a value: only a build from before D10 writes it, and such a build
// never touches the new key, so a present old key is always the newer value.

/// One CloudKit field of a record type.
struct FieldSpec: Hashable, Sendable {
    /// Persisted CloudKit field key. Never rename.
    let key: String
    /// Raw value of the owning field group, or nil for sync metadata.
    let group: String?
    /// True if the value is stored in `encryptedValues`.
    let encrypted: Bool
    /// The plain key this field replaced (D10 migration), or nil. Persisted: it stays declared in
    /// the schema, is cleared on every write and is read when an older build wrote it.
    let legacyKey: String?

    init<G: SyncFieldGroup>(_ key: String, _ group: G, encrypted: Bool = false, replacing legacyKey: String? = nil) {
        self.key = key
        self.group = group.rawValue
        self.encrypted = encrypted
        self.legacyKey = legacyKey
    }

    init(metaKey key: String) {
        self.key = key
        self.group = nil
        self.encrypted = false
        self.legacyKey = nil
    }

    private init(plainKey key: String, group: String?) {
        self.key = key
        self.group = group
        self.encrypted = false
        self.legacyKey = nil
    }

    /// The replaced plain field, as declared in the schema; nil when nothing was replaced.
    var legacy: FieldSpec? {
        legacyKey.map { FieldSpec(plainKey: $0, group: group) }
    }
}

/// Field keys of the sync metadata shared by every record type.
enum MetaFields {
    static let createdAt = FieldSpec(metaKey: "meta_createdAt")
    static let modifiedAt = FieldSpec(metaKey: "meta_modifiedAt")
    static let version = FieldSpec(metaKey: "meta_version")
    static let isTombstone = FieldSpec(metaKey: "meta_isTombstone")
    static let deletedAt = FieldSpec(metaKey: "meta_deletedAt")
    /// The writer's sync schema version (`RecordSchema.currentVersion`) as Int64. Added in D11;
    /// a record saved before it has none and counts as version 1. A build never overwrites a
    /// record whose server copy has a higher version (`CloudKitSyncStore`). Sync metadata, like
    /// `meta_version`: it is not a model value, so it joins no field group and is never merged.
    static let schemaVersion = FieldSpec(metaKey: "meta_schemaVersion")

    /// Timestamp of one field group.
    static func groupTime(_ group: String) -> FieldSpec {
        FieldSpec(metaKey: "groupTime_\(group)")
    }

    static func all(groups: [String]) -> [FieldSpec] {
        [createdAt, modifiedAt, version, isTombstone, deletedAt, schemaVersion] + groups.map(groupTime)
    }
}

enum ProfileFields {
    typealias G = Profile.FieldGroup
    static let name = FieldSpec("naming_name", G.naming, encrypted: true)
    /// `SearchEngine` raw value. Added after the first schema; records saved before it lack the
    /// key and decode with the default. Plain: a setting, not user content.
    static let searchEngine = FieldSpec("settings_searchEngine", G.settings)
    /// "Archive tabs after" in seconds (Double). Added after the first schema, like `searchEngine`.
    static let todayLifetime = FieldSpec("settings_todayLifetime", G.settings)
    /// "Include search engine suggestions" as 0/1 (Int64). Added in B66; records saved before it
    /// lack the key and decode as on (the default).
    static let includesSearchSuggestions = FieldSpec("settings_includesSearchSuggestions", G.settings)
    static let all = [name, searchEngine, todayLifetime, includesSearchSuggestions]
}

enum ThemeFields {
    typealias G = Theme.FieldGroup
    // Encrypted since D10: the colors a user picks for a Space are their own choice. The plain
    // keys of the first schema are the legacy keys.
    static let appearance = FieldSpec("style_appearanceEnc", G.style, encrypted: true, replacing: "style_appearance")
    /// JSON-encoded `[RGBAColor]`.
    static let colors = FieldSpec("style_colorsEnc", G.style, encrypted: true, replacing: "style_colors")
    static let grain = FieldSpec("style_grainEnc", G.style, encrypted: true, replacing: "style_grain")
    /// Records saved before brightness existed have neither key and decode with
    /// `Theme.defaultBrightness`.
    static let brightness = FieldSpec("style_brightnessEnc", G.style, encrypted: true, replacing: "style_brightness")
    static let all = [appearance, colors, grain, brightness]
}

enum SpaceFields {
    typealias G = Space.FieldGroup
    static let name = FieldSpec("naming_name", G.naming, encrypted: true)
    static let icon = FieldSpec("naming_icon", G.naming, encrypted: true)
    static let themeID = FieldSpec("theme_themeID", G.theme)
    static let profileID = FieldSpec("profile_profileID", G.profile)
    static let dockSortKey = FieldSpec("placement_dockSortKey", G.placement)
    static let all = [name, icon, themeID, profileID, dockSortKey]
}

enum FolderFields {
    typealias G = Folder.FieldGroup
    static let spaceID = FieldSpec("placement_spaceID", G.placement)
    static let parentFolderID = FieldSpec("placement_parentFolderID", G.placement)
    static let sortKey = FieldSpec("placement_sortKey", G.placement)
    static let title = FieldSpec("naming_title", G.naming, encrypted: true)
    /// Added in B77 (Change Icon…). Older records have none: decodes as nil.
    static let icon = FieldSpec("naming_icon", G.naming, encrypted: true)
    static let isExpanded = FieldSpec("display_isExpanded", G.display)
    static let all = [spaceID, parentFolderID, sortKey, title, icon, isExpanded]
}

enum TabFields {
    typealias G = TabNode.FieldGroup
    /// "favorite", "pinned" or "today".
    static let locationKind = FieldSpec("placement_kind", G.placement)
    static let profileID = FieldSpec("placement_profileID", G.placement)
    static let spaceID = FieldSpec("placement_spaceID", G.placement)
    static let folderID = FieldSpec("placement_folderID", G.placement)
    static let sortKey = FieldSpec("placement_sortKey", G.placement)
    static let url = FieldSpec("content_url", G.content, encrypted: true)
    static let title = FieldSpec("content_title", G.content, encrypted: true)
    static let faviconURL = FieldSpec("content_faviconURL", G.content, encrypted: true)
    static let customTitle = FieldSpec("naming_customTitle", G.naming, encrypted: true)
    /// Added in B77 (Change Icon…). Older records have none: decodes as nil.
    static let icon = FieldSpec("naming_icon", G.naming, encrypted: true)
    static let pinnedURL = FieldSpec("pin_url", G.pin, encrypted: true)
    static let lastActiveAt = FieldSpec("activity_lastActiveAt", G.activity)
    static let all = [locationKind, profileID, spaceID, folderID, sortKey, url, title, faviconURL, customTitle, icon, pinnedURL, lastActiveAt]
}

enum ArchiveItemFields {
    typealias G = ArchiveItem.FieldGroup
    static let url = FieldSpec("content_url", G.content, encrypted: true)
    static let title = FieldSpec("content_title", G.content, encrypted: true)
    static let faviconURL = FieldSpec("content_faviconURL", G.content, encrypted: true)
    static let folderPath = FieldSpec("content_folderPath", G.content, encrypted: true)
    static let spaceID = FieldSpec("content_spaceID", G.content)
    static let reason = FieldSpec("content_reason", G.content)
    static let archivedAt = FieldSpec("content_archivedAt", G.content)
    static let all = [url, title, faviconURL, folderPath, spaceID, reason, archivedAt]
}

enum SplitLayoutFields {
    typealias G = SplitLayout.FieldGroup
    static let spaceID = FieldSpec("layout_spaceID", G.layout)
    /// JSON-encoded `SplitNode` (tab ids and fractions only, no user content).
    static let root = FieldSpec("layout_root", G.layout)
    /// The split row's title and icon, added in B77 with the `naming` group. Older records have
    /// neither: both decode as nil.
    static let title = FieldSpec("naming_title", G.naming, encrypted: true)
    static let icon = FieldSpec("naming_icon", G.naming, encrypted: true)
    static let all = [spaceID, root, title, icon]
}

enum EaselFields {
    typealias G = Easel.FieldGroup
    static let title = FieldSpec("naming_title", G.naming, encrypted: true)
    static let all = [title]
}

enum EaselElementFields {
    typealias G = EaselElement.FieldGroup
    static let easelID = FieldSpec("placement_easelID", G.placement)
    static let zKey = FieldSpec("placement_zKey", G.placement)
    /// JSON-encoded `EaselRect`. Encrypted since D10: where and how large the user drew.
    static let frame = FieldSpec("geometry_frameEnc", G.geometry, encrypted: true, replacing: "geometry_frame")
    /// JSON-encoded `EaselElementContent` (text, inline image bytes, arrow ends, stroke points).
    /// Encrypted: it is what the user drew or wrote. Inline images are capped at
    /// `EaselImage.maxEncodedBytes`, which keeps the record under CloudKit's 1 MB limit.
    static let content = FieldSpec("content_payload", G.content, encrypted: true)
    /// JSON-encoded `EaselStyle` (colors and sizes). Encrypted since D10: part of the drawing.
    static let style = FieldSpec("style_styleEnc", G.style, encrypted: true, replacing: "style_style")
    static let all = [easelID, zKey, frame, content, style]
}

enum RecordSchema {
    /// Sync schema version this build writes (`MetaFields.schemaVersion`). Bump it when an older
    /// build would read a record of the new layout wrongly, or lose data by rewriting it.
    /// 1: records without the key (before D11). 2: D10 (encrypted theme style, easel geometry and
    /// style) and D11.
    static let currentVersion: Int64 = 2

    /// Raw values of the field groups of a record type.
    static func groups(of type: SyncRecordType) -> [String] {
        switch type {
        case .profile: return Profile.FieldGroup.allCases.map(\.rawValue)
        case .theme: return Theme.FieldGroup.allCases.map(\.rawValue)
        case .space: return Space.FieldGroup.allCases.map(\.rawValue)
        case .folder: return Folder.FieldGroup.allCases.map(\.rawValue)
        case .tab: return TabNode.FieldGroup.allCases.map(\.rawValue)
        case .archiveItem: return ArchiveItem.FieldGroup.allCases.map(\.rawValue)
        case .splitLayout: return SplitLayout.FieldGroup.allCases.map(\.rawValue)
        case .easel: return Easel.FieldGroup.allCases.map(\.rawValue)
        case .easelElement: return EaselElement.FieldGroup.allCases.map(\.rawValue)
        }
    }

    /// Content fields of a record type (excluding metadata).
    static func contentFields(of type: SyncRecordType) -> [FieldSpec] {
        switch type {
        case .profile: return ProfileFields.all
        case .theme: return ThemeFields.all
        case .space: return SpaceFields.all
        case .folder: return FolderFields.all
        case .tab: return TabFields.all
        case .archiveItem: return ArchiveItemFields.all
        case .splitLayout: return SplitLayoutFields.all
        case .easel: return EaselFields.all
        case .easelElement: return EaselElementFields.all
        }
    }

    /// Plain fields replaced by encrypted ones (D10). Still declared in the schema; every write
    /// clears them.
    static func legacyFields(of type: SyncRecordType) -> [FieldSpec] {
        contentFields(of: type).compactMap(\.legacy)
    }

    /// Every CloudKit field of a record type: content fields, legacy fields and metadata.
    static func fields(of type: SyncRecordType) -> [FieldSpec] {
        contentFields(of: type) + legacyFields(of: type) + MetaFields.all(groups: groups(of: type))
    }
}
