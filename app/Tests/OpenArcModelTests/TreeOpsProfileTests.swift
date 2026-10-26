import XCTest
@testable import OpenArcModel

/// Profile settings and profile deletion (A18). Spec: docs/arc-spec/03-settings.md §Profiles
/// (search engine default Google, "Archive tabs after" default 12 hours, per profile; "The
/// Default Profile cannot be deleted.", observed).
final class TreeOpsProfileTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let personal = UUID(), work = UUID()
    private let home = UUID(), office = UUID()

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Two profiles, each with one space.
    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: personal, name: "Personal", now: t0)
        s = TreeOps.createProfile(s, id: work, name: "Work", now: at(1))
        s = try TreeOps.createSpace(s, id: home, profileID: personal, name: "Home", now: t0)
        s = try TreeOps.createSpace(s, id: office, profileID: work, name: "Office", now: t0)
        return s
    }

    // MARK: Defaults and decoding

    /// [03 §Profiles] observed defaults: Google, 12 hours.
    func testNewProfileHasDefaultSettings() throws {
        let s = try base()
        XCTAssertEqual(s.profiles[personal]?.settings, ProfileSettings(searchEngine: .google, todayLifetime: 12 * hour))
        XCTAssertEqual(ProfileSettings.default.searchEngine, .google)
        XCTAssertEqual(ProfileSettings.default.todayLifetime, ArchivePolicy.defaultTodayLifetime)
        XCTAssertEqual(Profile.FieldGroup.allCases.map(\.rawValue), ["naming", "settings"])
    }

    /// JSON written before `Profile.settings` existed decodes with the defaults.
    func testOldProfileJSONWithoutSettingsDecodes() throws {
        let profile = Profile(id: personal, name: "Personal", settings: ProfileSettings(searchEngine: .bing, todayLifetime: hour), now: t0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "settings"))
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.settings, .default)
        XCTAssertEqual(decoded.name, "Personal")
        XCTAssertEqual(decoded.meta, profile.meta)
    }

    /// Partial or unknown settings decode leniently: missing keys and unknown engines (from a
    /// newer build) give defaults, a non-positive lifetime gives the default.
    func testSettingsDecodeLeniently() throws {
        let decode = { (text: String) in try JSONDecoder().decode(ProfileSettings.self, from: Data(text.utf8)) }
        XCTAssertEqual(try decode("{}"), .default)
        XCTAssertEqual(try decode(#"{"searchEngine":"kagi","todayLifetime":3600}"#), ProfileSettings(searchEngine: .google, todayLifetime: 3600))
        XCTAssertEqual(try decode(#"{"searchEngine":"ecosia","todayLifetime":0}"#), ProfileSettings(searchEngine: .ecosia))
        let roundTrip = ProfileSettings(searchEngine: .duckDuckGo, todayLifetime: 7 * 24 * hour)
        XCTAssertEqual(try JSONDecoder().decode(ProfileSettings.self, from: JSONEncoder().encode(roundTrip)), roundTrip)
    }

    // MARK: updateProfileSettings

    /// Stamps only `settings`; an unchanged value is a no-op; tombstoned profiles are refused.
    func testUpdateProfileSettingsStampsOnlySettings() throws {
        let s = try base()
        let new = ProfileSettings(searchEngine: .duckDuckGo, todayLifetime: 24 * hour)
        let out = try TreeOps.updateProfileSettings(s, id: personal, settings: new, now: at(100))
        let before = try XCTUnwrap(s.profiles[personal]), after = try XCTUnwrap(out.profiles[personal])
        XCTAssertEqual(after.settings, new)
        XCTAssertEqual(after.meta.modifiedAt(Profile.FieldGroup.settings), at(100))
        XCTAssertEqual(after.meta.modifiedAt(Profile.FieldGroup.naming), before.meta.modifiedAt(Profile.FieldGroup.naming))
        XCTAssertEqual(after.meta.version, before.meta.version + 1)
        XCTAssertEqual(out.profiles[work], s.profiles[work])

        XCTAssertEqual(try TreeOps.updateProfileSettings(out, id: personal, settings: new, now: at(200)), out)

        let fixed = try TreeOps.updateProfileSettings(s, id: personal, settings: ProfileSettings(todayLifetime: -5), now: at(100))
        XCTAssertEqual(fixed, s, "a non-positive lifetime becomes the default, which is unchanged")
    }

    func testUpdateProfileSettingsRefusesMissingOrDeletedProfile() throws {
        var s = try base()
        let ghost = UUID()
        XCTAssertThrowsError(try TreeOps.updateProfileSettings(s, id: ghost, settings: .default, now: t0)) {
            XCTAssertEqual($0 as? TreeError, .notFound(ghost))
        }
        s.profiles[work]?.meta.markDeleted(at: t0)
        XCTAssertThrowsError(try TreeOps.updateProfileSettings(s, id: work, settings: .default, now: t0)) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(work))
        }
    }

    // MARK: Per-profile auto-archive

    /// [03 §Profiles] observed: "Archive tabs after" belongs to the profile. Each Today tab uses
    /// its space's profile lifetime; pinned tabs stay; `excluding` still applies.
    func testAutoArchiveUsesEachTabsProfileLifetime() throws {
        var s = try base()
        s = try TreeOps.updateProfileSettings(s, id: work, settings: ProfileSettings(todayLifetime: 2 * hour), now: t0)
        let homeTab = UUID(), officeTab = UUID(), officePinned = UUID(), officeKept = UUID()
        s = try TreeOps.openTab(s, id: homeTab, spaceID: home, url: nil, title: "", now: t0)
        s = try TreeOps.openTab(s, id: officeTab, spaceID: office, url: nil, title: "", now: t0)
        s = try TreeOps.openTab(s, id: officeKept, spaceID: office, url: nil, title: "", now: t0)
        s = try TreeOps.openTab(s, id: officePinned, spaceID: office, url: nil, title: "", now: t0)
        s = try TreeOps.pinTab(s, id: officePinned, now: t0)

        let early = TreeOps.autoArchive(s, excluding: [officeKept], now: at(2 * hour - 1))
        XCTAssertTrue(early.archive.isEmpty)

        let out = TreeOps.autoArchive(s, excluding: [officeKept], now: at(3 * hour))
        XCTAssertEqual(out.archive[officeTab]?.reason, .autoArchived)
        XCTAssertNil(out.archive[homeTab], "Personal keeps the 12 h default")
        XCTAssertNil(out.archive[officePinned])
        XCTAssertEqual(out.tabs[officeKept], s.tabs[officeKept])

        let later = TreeOps.autoArchive(s, now: at(12 * hour))
        XCTAssertEqual(later.archive[homeTab]?.reason, .autoArchived)

        // The override replaces every profile's value.
        let overridden = TreeOps.autoArchive(s, lifetimeOverride: 24 * hour, now: at(12 * hour))
        XCTAssertTrue(overridden.archive.isEmpty)
    }

    /// A space whose profile is missing or deleted falls back to the default lifetime.
    func testLifetimeFallsBackToDefaultForOrphanedSpace() throws {
        var s = try base()
        s = try TreeOps.updateProfileSettings(s, id: work, settings: ProfileSettings(todayLifetime: hour), now: t0)
        XCTAssertEqual(s.todayLifetime(forSpace: office), hour)
        s.profiles[work]?.meta.markDeleted(at: t0)
        XCTAssertEqual(s.todayLifetime(forSpace: office), ArchivePolicy.defaultTodayLifetime)
        XCTAssertEqual(s.todayLifetime(forSpace: UUID()), ArchivePolicy.defaultTodayLifetime)
    }

    // MARK: deleteProfile

    /// [03 §Profiles] observed: the Default (oldest) profile cannot be deleted.
    func testDefaultProfileCannotBeDeleted() throws {
        var s = try base()
        s = try TreeOps.deleteSpace(s, id: home, now: at(5))
        XCTAssertEqual(s.defaultProfileID, personal)
        XCTAssertEqual(TreeOps.profileDeletionBlocker(s, id: personal), .defaultProfileNotDeletable)
        XCTAssertThrowsError(try TreeOps.deleteProfile(s, id: personal, now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .defaultProfileNotDeletable)
        }
    }

    /// [06 §16.3] observed: a profile that live spaces still use is refused; its spaces are
    /// neither moved nor deleted.
    func testProfileWithLiveSpacesCannotBeDeleted() throws {
        var s = try base()
        s = try TreeOps.createSpace(s, id: UUID(), profileID: work, name: "Second", now: t0)
        XCTAssertThrowsError(try TreeOps.deleteProfile(s, id: work, now: at(10))) {
            XCTAssertEqual($0 as? TreeError, .profileHasSpaces(2))
        }
        XCTAssertEqual(s.spaces(inProfile: work).count, 2)
        XCTAssertThrowsError(try TreeOps.deleteProfile(s, id: UUID(), now: at(10)))
    }

    /// inferred: deleting an unused profile archives its favorites and tombstones it; nothing
    /// else changes. Tombstoned spaces do not block.
    func testDeleteUnusedProfileArchivesFavoritesAndTombstones() throws {
        var s = try base()
        let fav = UUID(), otherFav = UUID()
        s = try TreeOps.openTab(s, id: fav, spaceID: office, url: URL(string: "https://w.example"), title: "W", now: t0)
        s = try TreeOps.moveTab(s, id: fav, to: .favorite(profileID: work), position: .last, now: t0)
        s = try TreeOps.openTab(s, id: otherFav, spaceID: home, url: nil, title: "P", now: t0)
        s = try TreeOps.moveTab(s, id: otherFav, to: .favorite(profileID: personal), position: .last, now: t0)
        s = try TreeOps.deleteSpace(s, id: office, now: at(5))
        XCTAssertNil(TreeOps.profileDeletionBlocker(s, id: work))

        let out = try TreeOps.deleteProfile(s, id: work, now: at(10))
        XCTAssertEqual(out.profiles[work]?.meta.isTombstone, true)
        XCTAssertEqual(out.profiles[work]?.meta.deletedAt, at(10))
        XCTAssertEqual(out.tabs[fav]?.meta.isTombstone, true)
        XCTAssertEqual(out.archive[fav]?.title, "W")
        XCTAssertEqual(out.archive[fav]?.reason, .spaceDeleted)
        XCTAssertEqual(out.tabs[otherFav], s.tabs[otherFav])
        XCTAssertEqual(out.profiles[personal], s.profiles[personal])
        XCTAssertEqual(out.liveProfilesOldestFirst.map(\.id), [personal])

        XCTAssertThrowsError(try TreeOps.deleteProfile(out, id: work, now: at(11))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(work))
        }
    }
}
