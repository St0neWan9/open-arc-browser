import Foundation
import OpenArcModel

/// Kinds of sync records. Raw values are the stable record type names from the model.
public enum SyncRecordType: String, Codable, CaseIterable, Hashable, Sendable {
    /// Local-only since B73 (see `isLocalOnly`). The case stays: the name is persisted (record
    /// names, the CloudKit schema) and older builds may still have written such records.
    case profile = "Profile"
    case theme = "Theme"
    case space = "Space"
    case folder = "Folder"
    case tab = "Tab"
    case archiveItem = "ArchiveItem"
    case splitLayout = "SplitLayout"
    /// Easels and their elements (B56).
    case easel = "Easel"
    case easelElement = "EaselElement"

    /// Record types that stay on this device: never uploaded (no save, no delete), and copies
    /// fetched from the server are ignored. Profiles are local (plan Q13): Arc's New Profile sheet
    /// says profiles are not synced between computers ([06 §16.3] observed). Records an older
    /// build already uploaded are left on the server untouched (deleting them would purge the
    /// profile on devices still running such a build). A synced Space or favorite that names a
    /// profile this device does not know resolves to the local Default profile
    /// (`WorkspaceState.localProfileID(for:)`).
    public var isLocalOnly: Bool { self == .profile }

    /// Every type that syncs, in declaration order.
    public static var syncedCases: [SyncRecordType] { allCases.filter { !$0.isLocalOnly } }

    /// Field groups whose values must be end-to-end encrypted by the backend (URLs, titles,
    /// names). docs/arc-spec/03-settings.md: "Arc Sync is end-to-end encrypted" (observed); the
    /// exact field split is our own decision.
    public var encryptedFieldGroups: Set<String> {
        switch self {
        case .profile: return [Profile.FieldGroup.naming.rawValue]
        case .theme: return []
        case .space: return [Space.FieldGroup.naming.rawValue]
        case .folder: return [Folder.FieldGroup.naming.rawValue]
        case .tab: return Set([TabNode.FieldGroup.content, .naming, .pin].map(\.rawValue))
        case .archiveItem: return [ArchiveItem.FieldGroup.content.rawValue]
        // The split row's own title and icon (B77) are user content; the pane tree stays plain.
        case .splitLayout: return [SplitLayout.FieldGroup.naming.rawValue]
        // The title, and what an element draws (text, image bytes, stroke shapes), are user
        // content. Geometry, stacking and style stay plain.
        case .easel: return [Easel.FieldGroup.naming.rawValue]
        case .easelElement: return [EaselElement.FieldGroup.content.rawValue]
        }
    }
}

/// Global identity of a record: type + UUID. (An `ArchiveItem` deliberately shares its UUID with
/// the archived tab, so the type is part of the identity.)
public struct SyncRecordID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var type: SyncRecordType
    public var uuid: UUID

    public init(type: SyncRecordType, uuid: UUID) {
        self.type = type
        self.uuid = uuid
    }

    /// Backend record name, e.g. "Tab/6F9619FF-…". Stable; never change the format.
    public var recordName: String { "\(type.rawValue)/\(uuid.uuidString)" }
    public var description: String { recordName }
}

/// A model value travelling through sync.
public enum SyncRecord: Hashable, Codable, Sendable {
    case profile(Profile)
    case theme(Theme)
    case space(Space)
    case folder(Folder)
    case tab(TabNode)
    case archiveItem(ArchiveItem)
    case splitLayout(SplitLayout)
    case easel(Easel)
    case easelElement(EaselElement)

    public var id: SyncRecordID {
        switch self {
        case .profile(let v): return SyncRecordID(type: .profile, uuid: v.id)
        case .theme(let v): return SyncRecordID(type: .theme, uuid: v.id)
        case .space(let v): return SyncRecordID(type: .space, uuid: v.id)
        case .folder(let v): return SyncRecordID(type: .folder, uuid: v.id)
        case .tab(let v): return SyncRecordID(type: .tab, uuid: v.id)
        case .archiveItem(let v): return SyncRecordID(type: .archiveItem, uuid: v.id)
        case .splitLayout(let v): return SyncRecordID(type: .splitLayout, uuid: v.id)
        case .easel(let v): return SyncRecordID(type: .easel, uuid: v.id)
        case .easelElement(let v): return SyncRecordID(type: .easelElement, uuid: v.id)
        }
    }

    public var meta: SyncMetadata {
        switch self {
        case .profile(let v): return v.meta
        case .theme(let v): return v.meta
        case .space(let v): return v.meta
        case .folder(let v): return v.meta
        case .tab(let v): return v.meta
        case .archiveItem(let v): return v.meta
        case .splitLayout(let v): return v.meta
        case .easel(let v): return v.meta
        case .easelElement(let v): return v.meta
        }
    }
}
