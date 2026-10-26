import Foundation
import OpenArcModel

/// Kinds of records that sync. Raw values are the stable record type names from the model.
public enum SyncRecordType: String, Codable, CaseIterable, Hashable, Sendable {
    case profile = "Profile"
    case theme = "Theme"
    case space = "Space"
    case folder = "Folder"
    case tab = "Tab"
    case archiveItem = "ArchiveItem"
    case splitLayout = "SplitLayout"

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
        case .splitLayout: return []
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

    public var id: SyncRecordID {
        switch self {
        case .profile(let v): return SyncRecordID(type: .profile, uuid: v.id)
        case .theme(let v): return SyncRecordID(type: .theme, uuid: v.id)
        case .space(let v): return SyncRecordID(type: .space, uuid: v.id)
        case .folder(let v): return SyncRecordID(type: .folder, uuid: v.id)
        case .tab(let v): return SyncRecordID(type: .tab, uuid: v.id)
        case .archiveItem(let v): return SyncRecordID(type: .archiveItem, uuid: v.id)
        case .splitLayout(let v): return SyncRecordID(type: .splitLayout, uuid: v.id)
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
        }
    }
}
