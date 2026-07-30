import CryptoKit
import Foundation

/// Automatic Project creation from Fetcher source collections (playlists and
/// rooms). Runs after a contract snapshot's provenance rows land in GRDB:
/// each playlist/room collection that resolves to at least one cached Navidrome
/// song gets exactly one Project, keyed deterministically on
/// `serverId + sourceCollectionKey`, so re-running is a free incremental upsert.
/// Album-kind collections are skipped — albums already have an identity in the
/// library and do not become Projects.
enum FetcherProjectAutomake {

    // MARK: - Lineage (pseudo-hierarchy category)

    /// Canonical category for a collection's lineage. The contract's top-level
    /// `domain` is hardcoded `apple_music`; the real lineage (the source's own
    /// taxonomy: Electronic / Dance / Classical / Jazz for playlists, classical /
    /// decades / dj-mixes for rooms) travels inside `source_specific_json.source_domain`.
    /// Playlist domains arrive capitalized, room domains as lowercase slugs —
    /// both normalize to one title-cased form.
    static func category(for collection: FetcherSourceCollection) -> String {
        normalizedCategory(sourceDomain(from: collection.sourceSpecificJson))
    }

    /// Extracts `source_domain` from the collection's raw source-specific JSON.
    static func sourceDomain(from sourceSpecificJson: String?) -> String? {
        guard let sourceSpecificJson,
              let data = sourceSpecificJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domain = object["source_domain"] as? String
        else { return nil }

        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Folds playlist-style ("Electronic") and room-slug-style ("dj-mixes",
    /// "apple_music_club") lineage values into one canonical title-cased form.
    static func normalizedCategory(_ rawDomain: String?) -> String {
        guard let rawDomain else { return "Other" }

        let slug = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !slug.isEmpty else { return "Other" }

        switch slug {
        case "dj-mixes": return "DJ Mixes"
        case "apple-music-club": return "Apple Music Club"
        case "other": return "Other"
        default:
            return slug
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: - Eligibility

    /// Playlists/rooms only — never albums. Kinds are open-ended strings from
    /// the contract, so this excludes by shape rather than allow-listing.
    static func isEligible(_ collection: FetcherSourceCollection) -> Bool {
        let kind = collection.sourceKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { return false }
        return !kind.localizedCaseInsensitiveContains("album")
    }

    // MARK: - Identity and naming

    /// Stable project id for a collection on a server. Re-running automake must
    /// upsert the same row (`upsertProject` is ON CONFLICT(id) DO UPDATE), so the
    /// id is a prefixed SHA-256 of the identity pair — nothing in the app parses
    /// project ids as UUIDs, so the shape change is safe.
    static func deterministicProjectId(serverId: String, sourceCollectionKey: String) -> String {
        let identity = "\(serverId)\u{1}\(sourceCollectionKey)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "fetcher-automake:\(hex)"
    }

    /// Playlist display names arrive as slugs ("hypnotic-techno"); rooms are
    /// already human ("Boiler Room"). Slugs title-case; existing spacing is
    /// preserved untouched.
    static func projectName(fromDisplayName displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled Source" }
        guard !trimmed.contains(" ") else { return trimmed }

        let words = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? trimmed : words.joined(separator: " ")
    }

    // MARK: - Run

    struct Summary: Sendable, Equatable {
        var createdProjectIds: [String] = []
        var updatedProjectIds: [String] = []
        var addedSongCount = 0
        var skippedArchivedCount = 0
        var unresolvedCollectionCount = 0

        var didChangeAnything: Bool {
            !createdProjectIds.isEmpty || !updatedProjectIds.isEmpty || addedSongCount > 0
        }
    }

    /// One pass over the snapshot's collections. Requires the snapshot's
    /// source-attribution rows to already be upserted (song resolution joins
    /// `source_attribution.navidrome_song_id` to `cached_songs.id`). Never archives,
    /// renames, or resurrects: a user-archived project is skipped outright, and an
    /// existing project only ever gains songs (and a category, if it had none).
    static func run(
        snapshot: FetcherContractSnapshot,
        serverId: String,
        database: DatabaseManager
    ) throws -> Summary {
        var summary = Summary()

        let songsByCollection = try database.songIdsBySourceCollectionKey(serverId: serverId)
        guard !songsByCollection.isEmpty else {
            summary.unresolvedCollectionCount = snapshot.sourceCollections.filter(isEligible).count
            return summary
        }

        let existingById = Dictionary(
            try database.loadProjects(serverId: serverId, includeArchived: true)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for collection in snapshot.sourceCollections where isEligible(collection) {
            guard let songIds = songsByCollection[collection.sourceCollectionKey],
                  !songIds.isEmpty
            else {
                summary.unresolvedCollectionCount += 1
                continue
            }

            let projectId = deterministicProjectId(
                serverId: serverId,
                sourceCollectionKey: collection.sourceCollectionKey
            )
            let itemNote = "Fetcher automake: \(collection.sourceCollectionKey)"

            if let existing = existingById[projectId] {
                guard existing.archivedAt == nil else {
                    summary.skippedArchivedCount += 1
                    continue
                }

                let insertResult = try database.addProjectSongReferences(
                    projectId: projectId,
                    songIds: songIds,
                    serverId: serverId,
                    addedBy: "fetcher_automake",
                    note: itemNote
                )
                if existing.category == nil {
                    try database.updateProjectCategory(
                        id: projectId,
                        serverId: serverId,
                        category: category(for: collection)
                    )
                }
                if insertResult.addedCount > 0 || existing.category == nil {
                    summary.updatedProjectIds.append(projectId)
                    summary.addedSongCount += insertResult.addedCount
                }
            } else {
                let project = Project(
                    id: projectId,
                    serverId: serverId,
                    name: projectName(fromDisplayName: collection.displayName),
                    kind: "collection",
                    notes: [
                        "Automade from Fetcher collection: \(collection.sourceCollectionKey)",
                        "Source kind: \(collection.sourceKind)"
                    ].joined(separator: "\n"),
                    category: category(for: collection)
                )
                let insertResult = try database.saveProjectWithSongReferences(
                    project,
                    songIds: songIds,
                    addedBy: "fetcher_automake",
                    note: itemNote
                )
                summary.createdProjectIds.append(projectId)
                summary.addedSongCount += insertResult.addedCount
            }
        }

        return summary
    }
}
