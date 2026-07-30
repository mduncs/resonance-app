import Foundation
import GRDB

struct LikedSongRow: Identifiable, Sendable, Hashable {
    var song: Song
    var serverId: String
    var source: String?
    var likedAt: Date

    var id: String { song.id }
}

struct ProjectSongReferenceInsertResult: Sendable, Equatable {
    let requestedCount: Int
    let uniqueRequestedCount: Int
    let addedItemIds: [String]
    let skippedExistingItemIds: [String]

    var addedCount: Int { addedItemIds.count }
    var skippedExistingCount: Int { skippedExistingItemIds.count }
}

struct ProjectProgress: Sendable, Equatable {
    let totalSongs: Int
    let heardCount: Int
    let markedCount: Int
    let remainingCount: Int
}

enum ProjectItemListenState {
    case unheard
    case heard
    case marked
}

private extension Row {
    func songFromCachedColumns(
        starredColumn: String = "starred_at",
        ratingColumn: String = "rating"
    ) -> Song {
        var song = Song(
            id: self["id"],
            title: self["title"],
            album: self["album_name"],
            albumId: self["album_id"],
            artist: self["artist_name"],
            artistId: self["artist_id"],
            track: self["track"],
            discNumber: self["disc_number"],
            year: self["year"],
            genre: self["genre"],
            duration: self["duration"],
            bitRate: self["bit_rate"],
            contentType: self["content_type"],
            suffix: self["suffix"],
            coverArt: self["cover_art_id"],
            starred: self[starredColumn],
            rating: self[ratingColumn]
        )
        // Present only after the v6 migration; GRDB yields nil for an absent
        // column, so queries that don't select `path` stay unaffected.
        song.path = self["path"]
        return song
    }

    func albumFromCachedColumns() -> Album {
        Album(
            id: self["id"],
            name: self["name"],
            artist: self["artist_name"],
            artistId: self["artist_id"],
            songCount: self["song_count"],
            duration: self["duration"],
            year: self["year"],
            genre: self["genre"],
            coverArt: self["cover_art_id"],
            starred: self["starred_at"],
            rating: self["rating"]
        )
    }

    func artistFromCachedColumns() -> Artist {
        Artist(
            id: self["id"],
            name: self["name"],
            albumCount: self["album_count"],
            coverArt: self["cover_art_id"],
            starred: self["starred_at"]
        )
    }
}

/// Central GRDB database manager for all local persistence.
/// Non-isolated Sendable class — GRDB handles its own scheduling via DatabasePool.
/// Replaces: SwiftData (CachedModels/DataStore), LibraryCache (JSON), PlayHistoryStore (UserDefaults).
final class DatabaseManager: Sendable {
    let dbPool: DatabasePool

    /// Database file path (exposed for companion service IPC)
    let dbPath: String

    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dbDir = appSupport.appendingPathComponent(
            PublicDemoConfiguration.appSupportDirectoryName,
            isDirectory: true
        )

        // Create directory with restricted permissions
        try FileManager.default.createDirectory(
            at: dbDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let path = dbDir.appendingPathComponent("resonance.db").path
        self.dbPath = path

        var config = Configuration()
        config.busyMode = .timeout(5.0) // 5s busy timeout for cross-process access
        config.prepareDatabase { db in
            // WAL mode for non-blocking reads during writes
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        dbPool = try DatabasePool(path: path, configuration: config)

        // Set file permissions after creation
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )

        // Run migrations
        try migrator.migrate(dbPool)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Speed up development by nuking db on schema change instead of crashing
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-core") { db in
            // -- Cached library data (replaces SwiftData + JSON cache) --

            try db.create(table: "cached_artists") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("album_count", .integer).notNull().defaults(to: 0)
                t.column("cover_art_id", .text)
                t.column("starred_at", .datetime)
                t.column("last_fetched", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_artists_server", on: "cached_artists", columns: ["server_id"])

            try db.create(table: "cached_albums") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("artist_name", .text).notNull()
                t.column("artist_id", .text).notNull()
                t.column("song_count", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("cover_art_id", .text)
                t.column("starred_at", .datetime)
                t.column("rating", .integer)
                t.column("last_fetched", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_albums_server", on: "cached_albums", columns: ["server_id"])
            try db.create(index: "idx_albums_artist", on: "cached_albums", columns: ["artist_id"])
            try db.create(index: "idx_albums_genre", on: "cached_albums", columns: ["genre"])

            try db.create(table: "cached_songs") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("album_name", .text).notNull()
                t.column("album_id", .text).notNull()
                t.column("artist_name", .text).notNull()
                t.column("artist_id", .text).notNull()
                t.column("track", .integer)
                t.column("disc_number", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("duration", .integer).notNull()
                t.column("bit_rate", .integer)
                t.column("content_type", .text).notNull()
                t.column("suffix", .text).notNull()
                t.column("cover_art_id", .text)
                t.column("starred_at", .datetime)
                t.column("rating", .integer)
                t.column("is_downloaded", .boolean).notNull().defaults(to: false)
                t.column("local_path", .text)
                t.column("downloaded_at", .datetime)
                t.column("last_fetched", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(index: "idx_songs_server", on: "cached_songs", columns: ["server_id"])
            try db.create(index: "idx_songs_album", on: "cached_songs", columns: ["album_id"])
            try db.create(index: "idx_songs_artist", on: "cached_songs", columns: ["artist_id"])

            try db.create(table: "cached_playlists") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("comment", .text)
                t.column("owner", .text).notNull()
                t.column("song_count", .integer).notNull().defaults(to: 0)
                t.column("duration", .integer).notNull().defaults(to: 0)
                t.column("created", .datetime).notNull()
                t.column("changed", .datetime).notNull()
                t.column("cover_art_id", .text)
                t.column("is_public", .boolean).notNull().defaults(to: false)
                t.column("last_fetched", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Playlists can have duplicate songs — PK is (playlist_id, position)
            try db.create(table: "cached_playlist_songs") { t in
                t.column("playlist_id", .text).notNull()
                t.column("song_id", .text).notNull()
                t.column("position", .integer).notNull()
                t.primaryKey(["playlist_id", "position"])
            }

            // -- Download tasks (replaces SwiftData DownloadTask) --

            try db.create(table: "download_tasks") { t in
                t.primaryKey("song_id", .text)
                t.column("server_id", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("started_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("error_message", .text)
            }

            // -- Local starred_at tracking (feature β) --

            try db.create(table: "starred_items") { t in
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull() // 'song', 'album', 'artist'
                t.column("server_id", .text).notNull()
                t.column("starred_at", .datetime).notNull()
                t.column("unstarred_at", .datetime)
                t.primaryKey(["item_id", "item_type", "server_id"])
            }
            try db.create(
                index: "idx_starred_type_date",
                on: "starred_items",
                columns: ["item_type", "starred_at"],
                condition: Column("unstarred_at") == nil
            )

            // -- Hidden items (feature δ) --

            try db.create(table: "hidden_items") { t in
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull() // 'song', 'album', 'artist'
                t.column("server_id", .text).notNull()
                t.column("hidden_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("reason", .text)
                t.primaryKey(["item_id", "item_type", "server_id"])
            }

            // -- Play history (feature δ, replaces UserDefaults PlayHistoryStore) --

            try db.create(table: "play_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("song_id", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("played_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("duration_played", .integer)
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("album_id", .text).notNull()
                t.column("cover_art", .text)
            }
            try db.create(index: "idx_history_date", on: "play_history", columns: ["played_at"])
            try db.create(index: "idx_history_song", on: "play_history", columns: ["song_id"])

            // -- Smart playlists (feature γ) --

            try db.create(table: "smart_playlists") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("rules_json", .text).notNull()
                t.column("sort_by", .text).notNull().defaults(to: "title")
                t.column("sort_order", .text).notNull().defaults(to: "asc")
                t.column("item_limit", .integer)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("last_evaluated", .datetime)
            }

            try db.create(table: "smart_playlist_results") { t in
                t.column("playlist_id", .text).notNull()
                    .references("smart_playlists", onDelete: .cascade)
                t.column("song_id", .text).notNull()
                t.column("position", .integer).notNull()
                t.primaryKey(["playlist_id", "song_id"])
            }

            // -- Discovery feed (feature ε) --

            try db.create(table: "discovered_albums") { t in
                t.column("album_id", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("discovered_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("source", .text)
                t.column("is_seen", .boolean).notNull().defaults(to: false)
                t.primaryKey(["album_id", "server_id"])
            }
            try db.create(index: "idx_discovered_date", on: "discovered_albums", columns: ["discovered_at"])

            // -- Source attribution (feature ε, populated by companion service) --

            try db.create(table: "source_attribution") { t in
                t.primaryKey("file_path", .text)
                t.column("source", .text).notNull()
                t.column("query", .text)
                t.column("added_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // -- Companion service IPC (feature ζ) --

            try db.create(table: "mgmt_requests") { t in
                t.primaryKey("id", .text)
                t.column("type", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("result_json", .text)
                t.column("error_message", .text)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("completed_at", .datetime)
            }
            try db.create(
                index: "idx_mgmt_pending",
                on: "mgmt_requests",
                columns: ["status"],
                condition: Column("status") == "pending"
            )

            // -- Sync metadata --

            try db.create(table: "sync_metadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // -- Fingerprints (feature η) --

            try db.create(table: "fingerprints") { t in
                t.primaryKey("song_id", .text)
                t.column("server_id", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("duration", .double).notNull()
                t.column("computed_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("v2-liked-items") { db in
            // Liked items — Resonance-only concept (not synced to navidrome).
            // Separate from starred_items (loved/heart) which syncs via navidrome star API.
            // Two-tier taste system: liked = "added to library" / loved = "I enjoy this"
            try db.create(table: "liked_items") { t in
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("liked_at", .datetime).notNull()
                t.column("source", .text) // 'apple_music', 'manual', 'import'
                t.primaryKey(["item_id", "item_type", "server_id"])
            }
            try db.create(
                index: "idx_liked_type_date",
                on: "liked_items",
                columns: ["item_type", "liked_at"]
            )
        }

        migrator.registerMigration("v3-liked-smart-playlist-indexes") { db in
            // Add indexes separately so existing v2 databases migrate in-place.
            try db.create(
                index: "idx_liked_type_server_date",
                on: "liked_items",
                columns: ["item_type", "server_id", "liked_at"]
            )
            try db.create(
                index: "idx_smart_playlists_server_name",
                on: "smart_playlists",
                columns: ["server_id", "name"]
            )
            try db.create(
                index: "idx_smart_playlist_results_playlist_position",
                on: "smart_playlist_results",
                columns: ["playlist_id", "position"]
            )
        }

        migrator.registerMigration("v4-curation-model") { db in
            try db.create(table: "library_membership") { t in
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("admitted_at", .datetime).notNull()
                t.column("admitted_by", .text).notNull()
                t.column("removed_at", .datetime)
                t.column("source_detail", .text)
                t.primaryKey(["item_id", "item_type", "server_id"])
            }
            try db.create(
                index: "idx_library_membership_active_type_date",
                on: "library_membership",
                columns: ["server_id", "item_type", "admitted_at"],
                condition: Column("removed_at") == nil
            )

            try db.create(table: "attention_marks") { t in
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("mark_type", .text).notNull()
                t.column("marked_at", .datetime).notNull()
                t.column("cleared_at", .datetime)
                t.column("source", .text)
                t.column("note", .text)
                t.primaryKey(["item_id", "item_type", "server_id", "mark_type"])
            }
            try db.create(
                index: "idx_attention_active_type_mark",
                on: "attention_marks",
                columns: ["server_id", "item_type", "mark_type", "marked_at"],
                condition: Column("cleared_at") == nil
            )

            try db.create(table: "projects") { t in
                t.primaryKey("id", .text)
                t.column("server_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull().defaults(to: "collection")
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("archived_at", .datetime)
                t.column("notes", .text)
            }
            try db.create(index: "idx_projects_server_name", on: "projects", columns: ["server_id", "name"])

            try db.create(table: "project_items") { t in
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("added_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("added_by", .text)
                t.column("note", .text)
                t.primaryKey(["project_id", "item_id", "item_type", "server_id"])
            }
            try db.create(
                index: "idx_project_items_project_position",
                on: "project_items",
                columns: ["project_id", "position"]
            )

            try db.create(table: "waiting_room_items") { t in
                t.column("song_id", .text).notNull()
                t.column("server_id", .text).notNull()
                t.column("state", .text).notNull().defaults(to: WaitingRoomState.unheard.rawValue)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("added_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("first_auditioned_at", .datetime)
                t.column("last_auditioned_at", .datetime)
                t.column("audition_count", .integer).notNull().defaults(to: 0)
                t.column("audition_seconds", .integer).notNull().defaults(to: 0)
                t.column("last_position_seconds", .integer)
                t.column("admitted_at", .datetime)
                t.column("rejected_at", .datetime)
                t.column("notes", .text)
                t.primaryKey(["song_id", "server_id"])
            }
            try db.create(
                index: "idx_waiting_room_server_state",
                on: "waiting_room_items",
                columns: ["server_id", "state", "updated_at"]
            )

            try db.execute(sql: """
                INSERT OR IGNORE INTO library_membership
                    (item_id, item_type, server_id, admitted_at, admitted_by)
                SELECT id, 'song', server_id, COALESCE(last_fetched, CURRENT_TIMESTAMP), 'navidrome_library'
                FROM cached_songs
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO library_membership
                    (item_id, item_type, server_id, admitted_at, admitted_by)
                SELECT id, 'album', server_id, COALESCE(last_fetched, CURRENT_TIMESTAMP), 'navidrome_library'
                FROM cached_albums
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO library_membership
                    (item_id, item_type, server_id, admitted_at, admitted_by)
                SELECT id, 'artist', server_id, COALESCE(last_fetched, CURRENT_TIMESTAMP), 'navidrome_library'
                FROM cached_artists
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO attention_marks
                    (item_id, item_type, server_id, mark_type, marked_at, source)
                SELECT item_id, item_type, server_id, 'liked', liked_at, source
                FROM liked_items
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO attention_marks
                    (item_id, item_type, server_id, mark_type, marked_at, cleared_at, source)
                SELECT item_id, item_type, server_id, 'loved', starred_at, unstarred_at, 'navidrome'
                FROM starred_items
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO attention_marks
                    (item_id, item_type, server_id, mark_type, marked_at, source, note)
                SELECT item_id, item_type, server_id, 'hidden', hidden_at, 'manual', reason
                FROM hidden_items
                """)
        }

        migrator.registerMigration("v5-source-attribution") { db in
            // Reshape the dormant v1 `source_attribution` table (which had zero
            // readers/writers) to match the Fetcher source-attribution contract.
            // Dropping is safe: nothing populated or queried the old shape.
            try db.drop(table: "source_attribution")
            try db.create(table: "source_attribution") { t in
                t.primaryKey("file_path", .text)
                t.column("attribution_key", .text)
                t.column("source_collection_key", .text)
                t.column("source_kind", .text)
                t.column("source_display_name", .text)
                t.column("download_source", .text)
                t.column("query_context", .text)
                t.column("acquired_at", .text)
                t.column("imported_at", .text)
            }
        }

        migrator.registerMigration("v6-cached-song-path") { db in
            // Persist Navidrome's music-folder-relative `Song.path` (added
            // decode-only in Phase 1) so album source-attribution joins can
            // resolve provenance from the cache without a re-fetch.
            try db.alter(table: "cached_songs") { t in
                t.add(column: "path", .text)
            }
        }

        migrator.registerMigration("v7-project-category") { db in
            // Lineage bucket for the Projects pseudo-hierarchy (Electronic /
            // Classical / ...). Nullable: hand-made projects have none and
            // group under "Uncategorized"; automade projects derive it from
            // the Fetcher collection's source_domain.
            try db.alter(table: "projects") { t in
                t.add(column: "category", .text)
            }
        }

        migrator.registerMigration("v8-path-match-key") { db in
            // Fetcher paths are absolute while Navidrome paths are relative to
            // a music-folder root, so exact equality cannot bridge them. Store
            // the same canonical trailing-component key on both sides and
            // index it; suffix scanning remains only for legacy NULL rows and
            // collision disambiguation.
            try Self.migratePathMatchKeys(db)
        }

        migrator.registerMigration("v9-source-attribution-song-id") { db in
            try Self.migrateSourceAttributionSongId(db)
        }

        return migrator
    }

    /// Adds the exact identity published by the Fetcher v2 attribution
    /// contract. Factored out so the schema change and index can be tested
    /// without reconstructing every preceding application migration.
    static func migrateSourceAttributionSongId(_ db: Database) throws {
        try db.alter(table: "source_attribution") { t in
            t.add(column: "navidrome_song_id", .text)
        }
        try db.create(
            index: "idx_source_attribution_navidrome_song_id",
            on: "source_attribution",
            columns: ["navidrome_song_id"]
        )
    }

    /// The v8 schema/data migration is factored for a focused migration test.
    /// Backfill updates are grouped into bounded CASE statements: this keeps
    /// statement size and memory stable for real libraries without issuing one
    /// SQLite UPDATE per row.
    static func migratePathMatchKeys(_ db: Database) throws {
        try db.alter(table: "cached_songs") { t in
            t.add(column: "match_key", .text)
        }
        try db.alter(table: "source_attribution") { t in
            t.add(column: "match_key", .text)
        }
        try backfillPathMatchKeys(
            db,
            table: "cached_songs",
            identityColumn: "id",
            pathColumn: "path"
        )
        try backfillPathMatchKeys(
            db,
            table: "source_attribution",
            identityColumn: "file_path",
            pathColumn: "file_path"
        )

        // Build indexes after the batched backfill so SQLite does not maintain
        // each B-tree incrementally across ~20k updates on an existing install.
        try db.create(
            index: "idx_cached_songs_match_key",
            on: "cached_songs",
            columns: ["match_key"]
        )
        try db.create(
            index: "idx_source_attribution_match_key",
            on: "source_attribution",
            columns: ["match_key"]
        )
    }

    private static func backfillPathMatchKeys(
        _ db: Database,
        table: String,
        identityColumn: String,
        pathColumn: String,
        batchSize: Int = 250
    ) throws {
        var lastIdentity: String?

        while true {
            let rows: [Row]
            if let lastIdentity {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(identityColumn), \(pathColumn)
                        FROM \(table)
                        WHERE \(identityColumn) > ?
                        ORDER BY \(identityColumn)
                        LIMIT ?
                        """,
                    arguments: [lastIdentity, batchSize]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(identityColumn), \(pathColumn)
                        FROM \(table)
                        ORDER BY \(identityColumn)
                        LIMIT ?
                        """,
                    arguments: [batchSize]
                )
            }
            guard !rows.isEmpty else { break }

            var assignments: [(identity: String, key: String?)] = []
            assignments.reserveCapacity(rows.count)
            for row in rows {
                let identity: String = row[identityColumn]
                let path: String? = row[pathColumn]
                assignments.append((identity, path.flatMap { PathMatchKey.canonical($0) }))
            }

            let cases = assignments.map { _ in "WHEN ? THEN ?" }.joined(separator: " ")
            let placeholders = Self.placeholders(assignments.count)
            var argumentValues: [DatabaseValue] = []
            argumentValues.reserveCapacity(assignments.count * 3)
            for assignment in assignments {
                argumentValues.append(assignment.identity.databaseValue)
                argumentValues.append(assignment.key?.databaseValue ?? .null)
            }
            argumentValues.append(contentsOf: assignments.map { $0.identity.databaseValue })
            try db.execute(
                sql: """
                    UPDATE \(table)
                    SET match_key = CASE \(identityColumn) \(cases) END
                    WHERE \(identityColumn) IN (\(placeholders))
                    """,
                arguments: StatementArguments(argumentValues)
            )

            lastIdentity = assignments.last?.identity
        }
    }

    // MARK: - Convenience read/write

    func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }

    func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbPool.write(block)
    }

    /// Shared by every cached-song insert so path persistence and join identity
    /// cannot drift apart when a song enters the cache through a different flow.
    private static func cachedSongPathValues(
        _ path: String?
    ) -> (path: String?, matchKey: String?) {
        (path, path.flatMap { PathMatchKey.canonical($0) })
    }

    // MARK: - Library Cache Operations

    /// Save albums from API fetch (column-specific upsert, preserves local-only fields)
    func saveAlbums(_ albums: [Album], serverId: String) throws {
        let shouldAdmitImportedMedia = ImportPolicyDefaults.shouldAdmitImportedMedia()

        try dbPool.write { db in
            for album in albums {
                try db.execute(
                    sql: """
                        INSERT INTO cached_albums
                            (id, server_id, name, artist_name, artist_id, song_count, duration,
                             year, genre, cover_art_id, starred_at, rating, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            server_id = excluded.server_id,
                            name = excluded.name,
                            artist_name = excluded.artist_name,
                            artist_id = excluded.artist_id,
                            song_count = excluded.song_count,
                            duration = excluded.duration,
                            year = excluded.year,
                            genre = excluded.genre,
                            cover_art_id = excluded.cover_art_id,
                            starred_at = excluded.starred_at,
                            rating = excluded.rating,
                            last_fetched = excluded.last_fetched
                        """,
                    arguments: [
                        album.id, serverId, album.name, album.artist, album.artistId,
                        album.songCount, album.duration, album.year, album.genre,
                        album.coverArt, album.starred, album.rating, Date()
                    ]
                )
                if shouldAdmitImportedMedia {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO library_membership
                                (item_id, item_type, server_id, admitted_at, admitted_by)
                            VALUES (?, 'album', ?, ?, ?)
                            """,
                        arguments: [album.id, serverId, Date(), LibraryAdmissionSource.navidromeLibrary.rawValue]
                    )
                }
            }
        }
    }

    /// Save artists from API fetch
    func saveArtists(_ artists: [Artist], serverId: String) throws {
        let shouldAdmitImportedMedia = ImportPolicyDefaults.shouldAdmitImportedMedia()

        try dbPool.write { db in
            for artist in artists {
                try db.execute(
                    sql: """
                        INSERT INTO cached_artists
                            (id, server_id, name, album_count, cover_art_id, starred_at, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            server_id = excluded.server_id,
                            name = excluded.name,
                            album_count = excluded.album_count,
                            cover_art_id = excluded.cover_art_id,
                            starred_at = excluded.starred_at,
                            last_fetched = excluded.last_fetched
                        """,
                    arguments: [
                        artist.id, serverId, artist.name, artist.albumCount,
                        artist.coverArt, artist.starred, Date()
                    ]
                )
                if shouldAdmitImportedMedia {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO library_membership
                                (item_id, item_type, server_id, admitted_at, admitted_by)
                            VALUES (?, 'artist', ?, ?, ?)
                            """,
                        arguments: [artist.id, serverId, Date(), LibraryAdmissionSource.navidromeLibrary.rawValue]
                    )
                }
            }
        }
    }

    /// Save songs from API fetch (preserves is_downloaded, local_path, downloaded_at)
    func saveSongs(_ songs: [Song], serverId: String) throws {
        let shouldAdmitImportedMedia = ImportPolicyDefaults.shouldAdmitImportedMedia()
        let shouldStageImports = ImportPolicyDefaults.shouldStageImportedSongs()

        try dbPool.write { db in
            for song in songs {
                let pathValues = Self.cachedSongPathValues(song.path)
                try db.execute(
                    sql: """
                        INSERT INTO cached_songs
                            (id, server_id, title, album_name, album_id, artist_name, artist_id,
                             track, disc_number, year, genre, duration, bit_rate,
                             content_type, suffix, cover_art_id, starred_at, rating, path, match_key, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            server_id = excluded.server_id,
                            title = excluded.title,
                            album_name = excluded.album_name,
                            album_id = excluded.album_id,
                            artist_name = excluded.artist_name,
                            artist_id = excluded.artist_id,
                            track = excluded.track,
                            disc_number = excluded.disc_number,
                            year = excluded.year,
                            genre = excluded.genre,
                            duration = excluded.duration,
                            bit_rate = excluded.bit_rate,
                            content_type = excluded.content_type,
                            suffix = excluded.suffix,
                            cover_art_id = excluded.cover_art_id,
                            starred_at = excluded.starred_at,
                            rating = excluded.rating,
                            path = COALESCE(excluded.path, cached_songs.path),
                            match_key = CASE
                                WHEN excluded.path IS NOT NULL THEN excluded.match_key
                                ELSE cached_songs.match_key
                            END,
                            last_fetched = excluded.last_fetched
                        """,
                    arguments: [
                        song.id, serverId, song.title, song.album, song.albumId,
                        song.artist, song.artistId, song.track, song.discNumber,
                        song.year, song.genre, song.duration, song.bitRate,
                        song.contentType, song.suffix, song.coverArt, song.starred,
                        song.rating, pathValues.path, pathValues.matchKey, Date()
                    ]
                )
                if shouldAdmitImportedMedia {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO library_membership
                                (item_id, item_type, server_id, admitted_at, admitted_by)
                            VALUES (?, 'song', ?, ?, ?)
                            """,
                        arguments: [song.id, serverId, Date(), LibraryAdmissionSource.navidromeLibrary.rawValue]
                    )
                } else if shouldStageImports {
                    try db.execute(
                        sql: """
                            INSERT INTO waiting_room_items
                                (song_id, server_id, state, source, added_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?)
                            ON CONFLICT(song_id, server_id) DO UPDATE SET
                                updated_at = excluded.updated_at
                            """,
                        arguments: [
                            song.id, serverId, WaitingRoomState.unheard.rawValue,
                            "server_import", Date(), Date()
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Stale Row Pruning

    /// Outcome of a generation sweep over one cached library table.
    ///
    /// `refusalReason` being non-nil means nothing was deleted. That is a
    /// deliberate outcome, not an error: the guard exists so that a sync which
    /// enumerated only part of the server cannot mass-delete rows it simply
    /// failed to see this time.
    /// A cached library table that participates in generation sweeps.
    ///
    /// Modelled as an enum rather than a string so the table name reaching SQL
    /// can only ever be one of these three literals.
    enum PrunableLibraryItem: String, Sendable, CaseIterable {
        case song
        case album
        case artist

        /// `library_membership.item_type` value for this kind.
        var itemType: String { rawValue }

        /// Name of the sync leg that populates this table, as used in
        /// `persistedLegs` and in the `lastSyncError.*` / `lastPrune` keys.
        var syncLeg: String {
            switch self {
            case .song: "songs"
            case .album: "albums"
            case .artist: "artists"
            }
        }

        var table: String {
            switch self {
            case .song: "cached_songs"
            case .album: "cached_albums"
            case .artist: "cached_artists"
            }
        }
    }

    struct LibraryPruneResult: Sendable, Equatable {
        let removed: Int
        let examined: Int
        let refusalReason: String?

        var wasRefused: Bool { refusalReason != nil }

        static let noop = LibraryPruneResult(removed: 0, examined: 0, refusalReason: nil)
    }

    /// Fraction of a cached table this sweep may remove before it refuses.
    ///
    /// Normal churn between syncs is a fraction of a percent. A sweep proposing
    /// to remove close to half the library is far more likely to be a partial
    /// enumeration than a real deletion event, so it declines and leaves a
    /// breadcrumb rather than acting. (The one genuine ~51% event in this
    /// library's history — a Navidrome reindex dropping a redundant tree — was
    /// resolved by an explicit one-off cleanup, which is the correct venue for
    /// a change of that size.)
    static let libraryPruneMaxRemovalFraction = 0.40

    /// Delete cached rows this server did not return during the current sync.
    ///
    /// Rows are identified by generation: `saveSongs`/`saveAlbums`/`saveArtists`
    /// stamp `last_fetched` on every row they touch, so anything still carrying
    /// a timestamp older than the sync's start was not returned by the server.
    ///
    /// Two invariants matter here:
    ///
    /// * Membership deletes are scoped to `admitted_by = 'navidrome_library'`.
    ///   Rows a human admitted are never swept by an automatic process.
    /// * Membership rows are hard-deleted rather than soft-marked via
    ///   `removed_at`. `removed_at` means "the user evicted this", and because
    ///   the save path re-admits with `INSERT OR IGNORE`, a lingering
    ///   soft-removed row would permanently block re-admission if the item ever
    ///   legitimately came back.
    ///
    /// - Parameter olderThan: the sync's start time; must be captured *before*
    ///   any leg persists, or the sweep will delete rows it just wrote.
    func pruneStaleLibraryRows(
        _ item: PrunableLibraryItem,
        serverId: String,
        olderThan: Date
    ) throws -> LibraryPruneResult {
        let table = item.table
        let itemType = item.itemType

        return try dbPool.write { db in
            let examined = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE server_id = ?",
                arguments: [serverId]
            ) ?? 0

            let candidates = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE server_id = ? AND last_fetched < ?",
                arguments: [serverId, olderThan]
            ) ?? 0

            guard candidates > 0 else {
                return LibraryPruneResult(removed: 0, examined: examined, refusalReason: nil)
            }

            let fraction = examined > 0 ? Double(candidates) / Double(examined) : 0
            guard fraction <= Self.libraryPruneMaxRemovalFraction else {
                let pct = Int((fraction * 100).rounded())
                return LibraryPruneResult(
                    removed: 0,
                    examined: examined,
                    refusalReason: "refused to prune \(candidates) of \(examined) \(itemType) rows "
                        + "(\(pct)%, over the \(Int(Self.libraryPruneMaxRemovalFraction * 100))% ceiling); "
                        + "a removal this large is more likely a partial sync than a real deletion"
                )
            }

            try db.execute(
                sql: """
                    DELETE FROM library_membership
                     WHERE item_type = ?
                       AND server_id = ?
                       AND admitted_by = 'navidrome_library'
                       AND item_id IN (
                           SELECT id FROM \(table)
                            WHERE server_id = ? AND last_fetched < ?
                       )
                    """,
                arguments: [itemType, serverId, serverId, olderThan]
            )

            try db.execute(
                sql: "DELETE FROM \(table) WHERE server_id = ? AND last_fetched < ?",
                arguments: [serverId, olderThan]
            )

            return LibraryPruneResult(removed: candidates, examined: examined, refusalReason: nil)
        }
    }

    /// Save playlists from API fetch
    func savePlaylists(_ playlists: [Playlist], serverId: String) throws {
        try dbPool.write { db in
            for playlist in playlists {
                try db.execute(
                    sql: """
                        INSERT INTO cached_playlists
                            (id, server_id, name, comment, owner, song_count, duration,
                             created, changed, cover_art_id, is_public, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            server_id = excluded.server_id,
                            name = excluded.name,
                            comment = excluded.comment,
                            owner = excluded.owner,
                            song_count = excluded.song_count,
                            duration = excluded.duration,
                            created = excluded.created,
                            changed = excluded.changed,
                            cover_art_id = excluded.cover_art_id,
                            is_public = excluded.is_public,
                            last_fetched = excluded.last_fetched
                        """,
                    arguments: [
                        playlist.id, serverId, playlist.name, playlist.comment,
                        playlist.owner, playlist.songCount, playlist.duration,
                        playlist.created, playlist.changed, playlist.coverArt,
                        playlist.isPublic, Date()
                    ]
                )
            }
        }
    }

    /// Load albums from cache
    func loadAlbums(serverId: String) throws -> [Album] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_albums WHERE server_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverId]
            )
            return rows.map { row in
                Album(
                    id: row["id"],
                    name: row["name"],
                    artist: row["artist_name"],
                    artistId: row["artist_id"],
                    songCount: row["song_count"],
                    duration: row["duration"],
                    year: row["year"],
                    genre: row["genre"],
                    coverArt: row["cover_art_id"],
                    starred: row["starred_at"],
                    rating: row["rating"]
                )
            }
        }
    }

    /// Load artists from cache
    func loadArtists(serverId: String) throws -> [Artist] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_artists WHERE server_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverId]
            )
            return rows.map { row in
                Artist(
                    id: row["id"],
                    name: row["name"],
                    albumCount: row["album_count"],
                    coverArt: row["cover_art_id"],
                    starred: row["starred_at"]
                )
            }
        }
    }

    /// Load all songs from cache (used by Apple Music importer for matching)
    func loadAllSongs(serverId: String) throws -> [Song] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_songs WHERE server_id = ?",
                arguments: [serverId]
            )
            return rows.map { $0.songFromCachedColumns() }
        }
    }

    func loadCachedSong(id: String, serverId: String) throws -> Song? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM cached_songs WHERE id = ? AND server_id = ?",
                arguments: [id, serverId]
            )?.songFromCachedColumns()
        }
    }

    // MARK: - Library Membership

    func admitToLibrary(
        id: String,
        type: LibraryItemType,
        serverId: String,
        admittedAt: Date = Date(),
        admittedBy: LibraryAdmissionSource = .manual,
        sourceDetail: String? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO library_membership
                        (item_id, item_type, server_id, admitted_at, admitted_by, removed_at, source_detail)
                    VALUES (?, ?, ?, ?, ?, NULL, ?)
                    ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                        admitted_at = excluded.admitted_at,
                        admitted_by = excluded.admitted_by,
                        removed_at = NULL,
                        source_detail = excluded.source_detail
                    """,
                arguments: [id, type.rawValue, serverId, admittedAt, admittedBy.rawValue, sourceDetail]
            )
        }
    }

    func admitSongAndRelated(
        _ song: Song,
        serverId: String,
        admittedAt: Date = Date(),
        admittedBy: LibraryAdmissionSource = .manual,
        sourceDetail: String? = nil
    ) throws {
        guard !song.id.isEmpty else { return }

        var items: [(id: String, type: LibraryItemType)] = [(song.id, .song)]
        if !song.albumId.isEmpty {
            items.append((song.albumId, .album))
        }
        if !song.artistId.isEmpty {
            items.append((song.artistId, .artist))
        }

        try dbPool.write { db in
            let pathValues = Self.cachedSongPathValues(song.path)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO cached_songs
                        (id, server_id, title, album_name, album_id, artist_name, artist_id,
                         track, disc_number, year, genre, duration, bit_rate,
                         content_type, suffix, cover_art_id, starred_at, rating, path, match_key, last_fetched)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    song.id, serverId, song.title, song.album, song.albumId,
                    song.artist, song.artistId, song.track, song.discNumber,
                    song.year, song.genre, song.duration, song.bitRate,
                    song.contentType, song.suffix, song.coverArt, song.starred,
                    song.rating, pathValues.path, pathValues.matchKey, admittedAt
                ]
            )

            if !song.albumId.isEmpty {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO cached_albums
                            (id, server_id, name, artist_name, artist_id, song_count, duration,
                             year, genre, cover_art_id, starred_at, rating, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        song.albumId,
                        serverId,
                        song.album.isEmpty ? "Unknown Album" : song.album,
                        song.artist.isEmpty ? "Unknown Artist" : song.artist,
                        song.artistId,
                        1,
                        song.duration,
                        song.year,
                        song.genre,
                        song.coverArt,
                        nil,
                        nil,
                        admittedAt
                    ]
                )
            }

            if !song.artistId.isEmpty {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO cached_artists
                            (id, server_id, name, album_count, cover_art_id, starred_at, last_fetched)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        song.artistId,
                        serverId,
                        song.artist.isEmpty ? "Unknown Artist" : song.artist,
                        1,
                        song.coverArt,
                        nil,
                        admittedAt
                    ]
                )
            }

            for item in items where !item.id.isEmpty {
                try db.execute(
                    sql: """
                        INSERT INTO library_membership
                            (item_id, item_type, server_id, admitted_at, admitted_by, removed_at, source_detail)
                        VALUES (?, ?, ?, ?, ?, NULL, ?)
                        ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                            admitted_at = excluded.admitted_at,
                            admitted_by = excluded.admitted_by,
                            removed_at = NULL,
                            source_detail = excluded.source_detail
                        """,
                    arguments: [
                        item.id,
                        item.type.rawValue,
                        serverId,
                        admittedAt,
                        admittedBy.rawValue,
                        sourceDetail
                    ]
                )
            }
        }
    }

    func removeFromLibrary(
        id: String,
        type: LibraryItemType,
        serverId: String,
        removedAt: Date = Date()
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE library_membership
                    SET removed_at = ?
                    WHERE item_id = ? AND item_type = ? AND server_id = ?
                    """,
                arguments: [removedAt, id, type.rawValue, serverId]
            )
        }
    }

    func unhideSongAndRelated(_ song: Song, serverId: String) throws {
        var items: [(id: String, type: String)] = [(song.id, "song")]
        if !song.albumId.isEmpty {
            items.append((song.albumId, "album"))
        }
        if !song.artistId.isEmpty {
            items.append((song.artistId, "artist"))
        }

        try dbPool.write { db in
            for item in items where !item.id.isEmpty {
                try db.execute(
                    sql: "DELETE FROM hidden_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
                    arguments: [item.id, item.type, serverId]
                )
            }
        }
    }

    func isInLibrary(id: String, type: LibraryItemType, serverId: String) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM library_membership
                        WHERE item_id = ? AND item_type = ? AND server_id = ? AND removed_at IS NULL
                    )
                    """,
                arguments: [id, type.rawValue, serverId]
            ) ?? false
        }
    }

    func loadLibraryMemberIds(type: LibraryItemType, serverId: String) throws -> Set<String> {
        try dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT item_id FROM library_membership
                    WHERE item_type = ? AND server_id = ? AND removed_at IS NULL
                    """,
                arguments: [type.rawValue, serverId]
            )
            return Set(ids)
        }
    }

    func loadAdmittedAlbums(serverId: String) throws -> [Album] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM cached_albums a
                    INNER JOIN library_membership lm
                        ON lm.item_id = a.id
                        AND lm.item_type = 'album'
                        AND lm.server_id = a.server_id
                        AND lm.removed_at IS NULL
                    WHERE a.server_id = ?
                    ORDER BY a.name COLLATE NOCASE
                    """,
                arguments: [serverId]
            )
            return rows.map { $0.albumFromCachedColumns() }
        }
    }

    func loadAdmittedArtists(serverId: String) throws -> [Artist] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM cached_artists a
                    INNER JOIN library_membership lm
                        ON lm.item_id = a.id
                        AND lm.item_type = 'artist'
                        AND lm.server_id = a.server_id
                        AND lm.removed_at IS NULL
                    WHERE a.server_id = ?
                    ORDER BY a.name COLLATE NOCASE
                    """,
                arguments: [serverId]
            )
            return rows.map { $0.artistFromCachedColumns() }
        }
    }

    func loadAdmittedSongs(serverId: String) throws -> [Song] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM cached_songs s
                    INNER JOIN library_membership lm
                        ON lm.item_id = s.id
                        AND lm.item_type = 'song'
                        AND lm.server_id = s.server_id
                        AND lm.removed_at IS NULL
                    WHERE s.server_id = ?
                    ORDER BY s.title COLLATE NOCASE
                    """,
                arguments: [serverId]
            )
            return rows.map { $0.songFromCachedColumns() }
        }
    }

    func loadUnclassifiedSongs(serverId: String, includeHidden: Bool = false) throws -> [Song] {
        try dbPool.read { db in
            let hiddenClause = includeHidden ? "" : "AND h.item_id IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM cached_songs s
                    LEFT JOIN library_membership lm
                        ON lm.item_id = s.id
                        AND lm.item_type = 'song'
                        AND lm.server_id = s.server_id
                        AND lm.removed_at IS NULL
                    LEFT JOIN hidden_items h
                        ON h.item_id = s.id
                        AND h.item_type = 'song'
                        AND h.server_id = s.server_id
                    WHERE s.server_id = ?
                        AND lm.item_id IS NULL
                        \(hiddenClause)
                    ORDER BY s.artist_name COLLATE NOCASE, s.album_name COLLATE NOCASE, s.track ASC
                    """,
                arguments: [serverId]
            )
            return rows.map { $0.songFromCachedColumns() }
        }
    }

    /// Number of cached songs with no library membership, not hidden, and no
    /// Waiting Room row (decided or undecided) — the set UnclassifiedView actually shows.
    func unclassifiedUndecidedCount(serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM cached_songs s
                    LEFT JOIN library_membership lm
                        ON lm.item_id = s.id
                        AND lm.item_type = 'song'
                        AND lm.server_id = s.server_id
                        AND lm.removed_at IS NULL
                    LEFT JOIN hidden_items h
                        ON h.item_id = s.id
                        AND h.item_type = 'song'
                        AND h.server_id = s.server_id
                    LEFT JOIN waiting_room_items w
                        ON w.song_id = s.id
                        AND w.server_id = s.server_id
                    WHERE s.server_id = ?
                        AND lm.item_id IS NULL
                        AND h.item_id IS NULL
                        AND w.song_id IS NULL
                    """,
                arguments: [serverId]
            ) ?? 0
        }
    }

    func loadAdmittedGenreSummaries(serverId: String) throws -> [Genre] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        s.genre AS name,
                        COUNT(DISTINCT s.id) AS song_count,
                        COUNT(DISTINCT s.album_id) AS album_count
                    FROM cached_songs s
                    INNER JOIN library_membership lm
                        ON lm.item_id = s.id
                        AND lm.item_type = 'song'
                        AND lm.server_id = s.server_id
                        AND lm.removed_at IS NULL
                    LEFT JOIN hidden_items h
                        ON h.item_id = s.id
                        AND h.item_type = 'song'
                        AND h.server_id = s.server_id
                    WHERE s.server_id = ?
                        AND s.genre IS NOT NULL
                        AND TRIM(s.genre) <> ''
                        AND h.item_id IS NULL
                    GROUP BY s.genre
                    ORDER BY album_count DESC, song_count DESC, name COLLATE NOCASE
                    """,
                arguments: [serverId]
            )
            return rows.map {
                Genre(
                    name: $0["name"],
                    songCount: $0["song_count"],
                    albumCount: $0["album_count"]
                )
            }
        }
    }

    // MARK: - Attention Marks

    func markAttention(
        id: String,
        type: LibraryItemType,
        serverId: String,
        markType: AttentionMarkType,
        markedAt: Date = Date(),
        source: String? = "manual",
        note: String? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO attention_marks
                        (item_id, item_type, server_id, mark_type, marked_at, cleared_at, source, note)
                    VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
                    ON CONFLICT(item_id, item_type, server_id, mark_type) DO UPDATE SET
                        marked_at = excluded.marked_at,
                        cleared_at = NULL,
                        source = excluded.source,
                        note = excluded.note
                    """,
                arguments: [id, type.rawValue, serverId, markType.rawValue, markedAt, source, note]
            )
        }
    }

    func clearAttention(
        id: String,
        type: LibraryItemType,
        serverId: String,
        markType: AttentionMarkType
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE attention_marks
                    SET cleared_at = ?
                    WHERE item_id = ? AND item_type = ? AND server_id = ? AND mark_type = ?
                    """,
                arguments: [Date(), id, type.rawValue, serverId, markType.rawValue]
            )
        }
    }

    func isAttentionMarked(
        id: String,
        type: LibraryItemType,
        serverId: String,
        markType: AttentionMarkType
    ) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM attention_marks
                        WHERE item_id = ? AND item_type = ? AND server_id = ?
                            AND mark_type = ? AND cleared_at IS NULL
                    )
                    """,
                arguments: [id, type.rawValue, serverId, markType.rawValue]
            ) ?? false
        }
    }

    func loadAttentionMarkedIds(
        type: LibraryItemType,
        markType: AttentionMarkType,
        serverId: String
    ) throws -> Set<String> {
        try dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT item_id FROM attention_marks
                    WHERE item_type = ? AND mark_type = ? AND server_id = ? AND cleared_at IS NULL
                    """,
                arguments: [type.rawValue, markType.rawValue, serverId]
            )
            return Set(ids)
        }
    }

    // MARK: - Projects

    func saveProject(_ project: Project) throws {
        try dbPool.write { db in
            try upsertProject(project, in: db)
        }
    }

    func loadProjects(serverId: String, includeArchived: Bool = false) throws -> [Project] {
        try dbPool.read { db in
            let archiveClause = includeArchived ? "" : "AND archived_at IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM projects
                    WHERE server_id = ? \(archiveClause)
                    ORDER BY updated_at DESC, name COLLATE NOCASE
                    """,
                arguments: [serverId]
            )
            return rows.map {
                Project(
                    id: $0["id"],
                    serverId: $0["server_id"],
                    name: $0["name"],
                    kind: $0["kind"],
                    createdAt: $0["created_at"],
                    updatedAt: $0["updated_at"],
                    archivedAt: $0["archived_at"],
                    notes: $0["notes"],
                    category: $0["category"]
                )
            }
        }
    }

    /// Sets the lineage category on an existing project without touching any
    /// other column (deliberately not bumping updated_at — a category backfill
    /// should not reshuffle the recency-ordered master list).
    func updateProjectCategory(id: String, serverId: String, category: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE projects SET category = ? WHERE id = ? AND server_id = ?",
                arguments: [category, id, serverId]
            )
        }
    }

    func archiveProject(id: String, serverId: String, archivedAt: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE projects
                    SET archived_at = ?, updated_at = ?
                    WHERE id = ? AND server_id = ?
                    """,
                arguments: [archivedAt, archivedAt, id, serverId]
            )
        }
    }

    func addProjectItem(
        projectId: String,
        itemId: String,
        itemType: LibraryItemType,
        serverId: String,
        position: Int,
        addedBy: String? = "manual",
        note: String? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO project_items
                        (project_id, item_id, item_type, server_id, position, added_at, added_by, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_id, item_id, item_type, server_id) DO UPDATE SET
                        position = excluded.position,
                        added_by = excluded.added_by,
                        note = excluded.note
                    """,
                arguments: [projectId, itemId, itemType.rawValue, serverId, position, Date(), addedBy, note]
            )
        }
    }

    func saveProjectWithSongReferences(
        _ project: Project,
        songIds: [String],
        addedBy: String? = "manual",
        note: String? = nil
    ) throws -> ProjectSongReferenceInsertResult {
        try dbPool.write { db in
            try upsertProject(project, in: db)
            return try insertProjectSongReferences(
                db: db,
                projectId: project.id,
                songIds: songIds,
                serverId: project.serverId,
                addedBy: addedBy,
                note: note
            )
        }
    }

    func addProjectSongReferences(
        projectId: String,
        songIds: [String],
        serverId: String,
        addedBy: String? = "manual",
        note: String? = nil
    ) throws -> ProjectSongReferenceInsertResult {
        try dbPool.write { db in
            try insertProjectSongReferences(
                db: db,
                projectId: projectId,
                songIds: songIds,
                serverId: serverId,
                addedBy: addedBy,
                note: note
            )
        }
    }

    func nextProjectItemPosition(projectId: String, serverId: String) throws -> Int {
        try dbPool.read { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(position) FROM project_items
                    WHERE project_id = ? AND server_id = ?
                    """,
                arguments: [projectId, serverId]
            )
            return (maxPosition ?? -1) + 1
        }
    }

    func loadProjectItems(projectId: String, serverId: String) throws -> [ProjectItem] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM project_items
                    WHERE project_id = ? AND server_id = ?
                    ORDER BY position ASC, added_at ASC
                    """,
                arguments: [projectId, serverId]
            )
            return rows.map {
                ProjectItem(
                    projectId: $0["project_id"],
                    itemId: $0["item_id"],
                    itemType: LibraryItemType(rawValue: $0["item_type"] as String) ?? .song,
                    serverId: $0["server_id"],
                    position: $0["position"],
                    addedAt: $0["added_at"],
                    addedBy: $0["added_by"],
                    note: $0["note"]
                )
            }
        }
    }

    func loadProjectSongs(projectId: String, serverId: String) throws -> [Song] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM project_items pi
                    INNER JOIN cached_songs s
                        ON s.id = pi.item_id
                        AND s.server_id = pi.server_id
                    WHERE pi.project_id = ?
                        AND pi.server_id = ?
                        AND pi.item_type = 'song'
                    ORDER BY pi.position ASC, pi.added_at ASC
                    """,
                arguments: [projectId, serverId]
            )
            return rows.map { $0.songFromCachedColumns() }
        }
    }

    func projectProgress(projectId: String, serverId: String) throws -> ProjectProgress {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS total_songs,
                        COALESCE(SUM(
                            CASE WHEN EXISTS(
                                SELECT 1 FROM play_history ph
                                WHERE ph.song_id = s.id
                                    AND ph.server_id = s.server_id
                            ) THEN 1 ELSE 0 END
                        ), 0) AS heard_count,
                        COALESCE(SUM(
                            CASE WHEN
                                EXISTS(
                                    SELECT 1 FROM attention_marks am
                                    WHERE am.item_id = s.id
                                        AND am.item_type = 'song'
                                        AND am.server_id = s.server_id
                                        AND am.cleared_at IS NULL
                                )
                                OR EXISTS(
                                    SELECT 1 FROM liked_items li
                                    WHERE li.item_id = s.id
                                        AND li.item_type = 'song'
                                        AND li.server_id = s.server_id
                                )
                                OR EXISTS(
                                    SELECT 1 FROM starred_items si
                                    WHERE si.item_id = s.id
                                        AND si.item_type = 'song'
                                        AND si.server_id = s.server_id
                                        AND si.unstarred_at IS NULL
                                )
                            THEN 1 ELSE 0 END
                        ), 0) AS marked_count
                    FROM project_items pi
                    INNER JOIN cached_songs s
                        ON s.id = pi.item_id
                        AND s.server_id = pi.server_id
                    WHERE pi.project_id = ?
                        AND pi.server_id = ?
                        AND pi.item_type = 'song'
                    """,
                arguments: [projectId, serverId]
            )

            let totalSongs: Int = row?["total_songs"] ?? 0
            let heardCount: Int = row?["heard_count"] ?? 0
            let markedCount: Int = row?["marked_count"] ?? 0
            return ProjectProgress(
                totalSongs: totalSongs,
                heardCount: heardCount,
                markedCount: markedCount,
                remainingCount: totalSongs - heardCount
            )
        }
    }

    func projectItemListenStates(
        projectId: String,
        serverId: String
    ) throws -> [String: ProjectItemListenState] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        s.id,
                        EXISTS(
                            SELECT 1 FROM play_history ph
                            WHERE ph.song_id = s.id
                                AND ph.server_id = s.server_id
                        ) AS is_heard,
                        (
                            EXISTS(
                                SELECT 1 FROM attention_marks am
                                WHERE am.item_id = s.id
                                    AND am.item_type = 'song'
                                    AND am.server_id = s.server_id
                                    AND am.cleared_at IS NULL
                            )
                            OR EXISTS(
                                SELECT 1 FROM liked_items li
                                WHERE li.item_id = s.id
                                    AND li.item_type = 'song'
                                    AND li.server_id = s.server_id
                            )
                            OR EXISTS(
                                SELECT 1 FROM starred_items si
                                WHERE si.item_id = s.id
                                    AND si.item_type = 'song'
                                    AND si.server_id = s.server_id
                                    AND si.unstarred_at IS NULL
                            )
                        ) AS is_marked
                    FROM project_items pi
                    INNER JOIN cached_songs s
                        ON s.id = pi.item_id
                        AND s.server_id = pi.server_id
                    WHERE pi.project_id = ?
                        AND pi.server_id = ?
                        AND pi.item_type = 'song'
                    ORDER BY pi.position ASC, pi.added_at ASC
                    """,
                arguments: [projectId, serverId]
            )

            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let songId: String = row["id"]
                let isHeard: Bool = row["is_heard"]
                let isMarked: Bool = row["is_marked"]
                let state: ProjectItemListenState
                if isMarked {
                    state = .marked
                } else if isHeard {
                    state = .heard
                } else {
                    state = .unheard
                }
                return (songId, state)
            })
        }
    }

    func projectNextUp(projectId: String, serverId: String, limit: Int) throws -> [Song] {
        guard limit > 0 else { return [] }

        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM project_items pi
                    INNER JOIN cached_songs s
                        ON s.id = pi.item_id
                        AND s.server_id = pi.server_id
                    WHERE pi.project_id = ?
                        AND pi.server_id = ?
                        AND pi.item_type = 'song'
                    ORDER BY
                        CASE WHEN EXISTS(
                            SELECT 1 FROM play_history ph
                            WHERE ph.song_id = s.id
                                AND ph.server_id = s.server_id
                        ) THEN 1 ELSE 0 END ASC,
                        pi.position ASC,
                        pi.added_at ASC
                    LIMIT ?
                    """,
                arguments: [projectId, serverId, limit]
            )
            return rows.map { $0.songFromCachedColumns() }
        }
    }

    func removeProjectItem(
        projectId: String,
        itemId: String,
        itemType: LibraryItemType,
        serverId: String
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM project_items
                    WHERE project_id = ? AND item_id = ? AND item_type = ? AND server_id = ?
                    """,
                arguments: [projectId, itemId, itemType.rawValue, serverId]
            )
        }
    }

    private func upsertProject(_ project: Project, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO projects
                    (id, server_id, name, kind, created_at, updated_at, archived_at, notes, category)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    server_id = excluded.server_id,
                    name = excluded.name,
                    kind = excluded.kind,
                    updated_at = excluded.updated_at,
                    archived_at = excluded.archived_at,
                    notes = excluded.notes,
                    category = excluded.category
                """,
            arguments: [
                project.id, project.serverId, project.name, project.kind,
                project.createdAt, project.updatedAt, project.archivedAt, project.notes,
                project.category
            ]
        )
    }

    private func insertProjectSongReferences(
        db: Database,
        projectId: String,
        songIds: [String],
        serverId: String,
        addedBy: String?,
        note: String?
    ) throws -> ProjectSongReferenceInsertResult {
        let uniqueSongIds = uniqueNonEmptyValues(songIds)
        let existingSongIds = Set(try String.fetchAll(
            db,
            sql: """
                SELECT item_id FROM project_items
                WHERE project_id = ? AND server_id = ? AND item_type = ?
                """,
            arguments: [projectId, serverId, LibraryItemType.song.rawValue]
        ))
        let maxPosition = try Int.fetchOne(
            db,
            sql: """
                SELECT MAX(position) FROM project_items
                WHERE project_id = ? AND server_id = ?
                """,
            arguments: [projectId, serverId]
        )
        var position = (maxPosition ?? -1) + 1
        var addedItemIds: [String] = []
        var skippedExistingItemIds: [String] = []

        for songId in uniqueSongIds {
            guard !existingSongIds.contains(songId) else {
                skippedExistingItemIds.append(songId)
                continue
            }

            try db.execute(
                sql: """
                    INSERT INTO project_items
                        (project_id, item_id, item_type, server_id, position, added_at, added_by, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    projectId,
                    songId,
                    LibraryItemType.song.rawValue,
                    serverId,
                    position,
                    Date(),
                    addedBy,
                    note
                ]
            )
            addedItemIds.append(songId)
            position += 1
        }

        return ProjectSongReferenceInsertResult(
            requestedCount: songIds.count,
            uniqueRequestedCount: uniqueSongIds.count,
            addedItemIds: addedItemIds,
            skippedExistingItemIds: skippedExistingItemIds
        )
    }

    private func uniqueNonEmptyValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            result.append(value)
        }

        return result
    }

    // MARK: - Waiting Room

    func upsertWaitingRoomItem(
        song: Song,
        serverId: String,
        state: WaitingRoomState = .unheard,
        source: String = "manual",
        notes: String? = nil
    ) throws {
        try dbPool.write { db in
            let pathValues = Self.cachedSongPathValues(song.path)
            try db.execute(
                sql: """
                    INSERT INTO waiting_room_items
                        (song_id, server_id, state, source, added_at, updated_at, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(song_id, server_id) DO UPDATE SET
                        state = CASE
                            WHEN waiting_room_items.state IN ('admitted', 'rejected')
                            THEN waiting_room_items.state
                            ELSE excluded.state
                        END,
                        source = CASE
                            WHEN waiting_room_items.state IN ('admitted', 'rejected')
                                AND excluded.state NOT IN ('admitted', 'rejected')
                            THEN waiting_room_items.source
                            ELSE excluded.source
                        END,
                        updated_at = CASE
                            WHEN waiting_room_items.state IN ('admitted', 'rejected')
                                AND excluded.state NOT IN ('admitted', 'rejected')
                            THEN waiting_room_items.updated_at
                            ELSE excluded.updated_at
                        END,
                        notes = CASE
                            WHEN waiting_room_items.state IN ('admitted', 'rejected')
                                AND excluded.state NOT IN ('admitted', 'rejected')
                            THEN waiting_room_items.notes
                            ELSE COALESCE(excluded.notes, waiting_room_items.notes)
                        END
                    """,
                arguments: [song.id, serverId, state.rawValue, source, Date(), Date(), notes]
            )
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO cached_songs
                        (id, server_id, title, album_name, album_id, artist_name, artist_id,
                         track, disc_number, year, genre, duration, bit_rate,
                         content_type, suffix, cover_art_id, starred_at, rating, path, match_key, last_fetched)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    song.id, serverId, song.title, song.album, song.albumId,
                    song.artist, song.artistId, song.track, song.discNumber,
                    song.year, song.genre, song.duration, song.bitRate,
                    song.contentType, song.suffix, song.coverArt, song.starred,
                    song.rating, pathValues.path, pathValues.matchKey, Date()
                ]
            )
        }
    }

    func setWaitingRoomState(
        songId: String,
        serverId: String,
        state: WaitingRoomState,
        notes: String? = nil
    ) throws {
        let now = Date()
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE waiting_room_items
                    SET state = ?,
                        updated_at = ?,
                        admitted_at = CASE WHEN ? = 'admitted' THEN ? ELSE admitted_at END,
                        rejected_at = CASE WHEN ? = 'rejected' THEN ? ELSE rejected_at END,
                        notes = COALESCE(?, notes)
                    WHERE song_id = ? AND server_id = ?
                    """,
                arguments: [
                    state.rawValue, now,
                    state.rawValue, now,
                    state.rawValue, now,
                    notes, songId, serverId
                ]
            )
        }
    }

    func incrementWaitingRoomAudition(
        songId: String,
        serverId: String,
        seconds: Int,
        lastPositionSeconds: Int? = nil
    ) throws {
        let now = Date()
        let shouldMarkPartial = ImportPolicyDefaults.bool(
            for: ImportPolicyDefaults.autoMarkPartialAuditions,
            default: true
        )
        let shouldMarkHeard = ImportPolicyDefaults.bool(
            for: ImportPolicyDefaults.autoMarkHeardAuditions,
            default: true
        )
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE waiting_room_items
                    SET first_auditioned_at = COALESCE(first_auditioned_at, ?),
                        last_auditioned_at = ?,
                        audition_count = audition_count + 1,
                        audition_seconds = audition_seconds + ?,
                        last_position_seconds = COALESCE(?, last_position_seconds),
                        state = CASE
                            WHEN state IN ('admitted', 'rejected', 'interesting') THEN state
                            WHEN ? = 1 AND audition_count >= 1 THEN 'replayed'
                            WHEN ? = 1 AND ? >= 90 THEN 'heard'
                            WHEN ? = 1 AND ? > 0 THEN 'partly_heard'
                            ELSE state
                        END,
                        updated_at = ?
                    WHERE song_id = ? AND server_id = ?
                    """,
                arguments: [
                    now, now, seconds, lastPositionSeconds,
                    shouldMarkHeard ? 1 : 0,
                    shouldMarkHeard ? 1 : 0, seconds,
                    shouldMarkPartial ? 1 : 0, seconds,
                    now, songId, serverId
                ]
            )
        }
    }

    func loadWaitingRoomItems(serverId: String, includeDecided: Bool = false) throws -> [WaitingRoomItem] {
        try dbPool.read { db in
            let decidedClause = includeDecided ? "" : "AND w.state NOT IN ('admitted', 'rejected')"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        s.*,
                        w.server_id AS waiting_server_id,
                        w.state AS waiting_state,
                        w.source AS waiting_source,
                        w.added_at AS waiting_added_at,
                        w.updated_at AS waiting_updated_at,
                        w.first_auditioned_at,
                        w.last_auditioned_at,
                        w.audition_count,
                        w.audition_seconds,
                        w.last_position_seconds,
                        w.admitted_at,
                        w.rejected_at,
                        w.notes AS waiting_notes
                    FROM waiting_room_items w
                    INNER JOIN cached_songs s
                        ON s.id = w.song_id AND s.server_id = w.server_id
                    WHERE w.server_id = ? \(decidedClause)
                    ORDER BY w.updated_at DESC
                    """,
                arguments: [serverId]
            )
            return rows.map { row in
                WaitingRoomItem(
                    song: row.songFromCachedColumns(),
                    serverId: row["waiting_server_id"],
                    state: WaitingRoomState(rawValue: row["waiting_state"] as String) ?? .unheard,
                    source: row["waiting_source"],
                    addedAt: row["waiting_added_at"],
                    updatedAt: row["waiting_updated_at"],
                    firstAuditionedAt: row["first_auditioned_at"],
                    lastAuditionedAt: row["last_auditioned_at"],
                    auditionCount: row["audition_count"],
                    auditionSeconds: row["audition_seconds"],
                    lastPositionSeconds: row["last_position_seconds"],
                    admittedAt: row["admitted_at"],
                    rejectedAt: row["rejected_at"],
                    notes: row["waiting_notes"]
                )
            }
        }
    }

    /// Load playlists from cache
    func loadPlaylists(serverId: String) throws -> [Playlist] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_playlists WHERE server_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverId]
            )
            return rows.map { row in
                Playlist(
                    id: row["id"],
                    name: row["name"],
                    comment: row["comment"],
                    owner: row["owner"],
                    songCount: row["song_count"],
                    duration: row["duration"],
                    created: row["created"],
                    changed: row["changed"],
                    coverArt: row["cover_art_id"],
                    isPublic: row["is_public"]
                )
            }
        }
    }

    // MARK: - Play History

    /// Record a song play, returns the row ID for later duration update
    @discardableResult
    func recordPlay(song: Song, serverId: String, durationPlayed: Int? = nil) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO play_history
                        (song_id, server_id, played_at, duration_played,
                         title, artist, album, album_id, cover_art)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    song.id, serverId, Date(), durationPlayed,
                    song.title, song.artist, song.album, song.albumId, song.coverArt
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Update the duration_played for a play history entry (called when track ends/skips)
    func updatePlayDuration(historyId: Int64, durationPlayed: Int) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE play_history SET duration_played = ? WHERE id = ?",
                arguments: [durationPlayed, historyId]
            )
        }
    }

    /// Load play history (most recent first)
    func loadPlayHistory(serverId: String? = nil, limit: Int = 100) throws -> [PlayHistoryEntry] {
        try dbPool.read { db in
            let rows: [Row]
            if let serverId {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM play_history
                        WHERE server_id = ?
                        ORDER BY played_at DESC
                        LIMIT ?
                        """,
                    arguments: [serverId, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM play_history ORDER BY played_at DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return rows.map { row in
                PlayHistoryEntry(
                    id: row["id"],
                    songId: row["song_id"],
                    serverId: row["server_id"],
                    playedAt: row["played_at"],
                    durationPlayed: row["duration_played"],
                    title: row["title"],
                    artist: row["artist"],
                    album: row["album"],
                    albumId: row["album_id"],
                    coverArt: row["cover_art"]
                )
            }
        }
    }

    // MARK: - Play History Aggregation

    /// Get play count for a specific song
    func playCount(songId: String, serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM play_history WHERE song_id = ? AND server_id = ?",
                arguments: [songId, serverId]
            ) ?? 0
        }
    }

    /// Get most played songs with play counts
    func mostPlayedSongs(serverId: String, limit: Int = 50) throws -> [(songId: String, title: String, artist: String, album: String, albumId: String, coverArt: String?, playCount: Int, totalDuration: Int)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT song_id, title, artist, album, album_id, cover_art,
                           COUNT(*) as play_count,
                           COALESCE(SUM(duration_played), 0) as total_duration
                    FROM play_history
                    WHERE server_id = ?
                    GROUP BY song_id
                    ORDER BY play_count DESC
                    LIMIT ?
                    """,
                arguments: [serverId, limit]
            )
            return rows.map { row in
                (
                    songId: row["song_id"] as String,
                    title: row["title"] as String,
                    artist: row["artist"] as String,
                    album: row["album"] as String,
                    albumId: row["album_id"] as String,
                    coverArt: row["cover_art"] as String?,
                    playCount: row["play_count"] as Int,
                    totalDuration: row["total_duration"] as Int
                )
            }
        }
    }

    /// Get total listening time in seconds
    func totalListeningTime(serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(duration_played), 0) FROM play_history WHERE server_id = ?",
                arguments: [serverId]
            ) ?? 0
        }
    }

    /// Get play count for songs within a date range (for smart playlists)
    func playCountsInRange(serverId: String, since: Date) throws -> [String: Int] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT song_id, COUNT(*) as play_count
                    FROM play_history
                    WHERE server_id = ? AND played_at >= ?
                    GROUP BY song_id
                    """,
                arguments: [serverId, since]
            )
            var result: [String: Int] = [:]
            for row in rows {
                result[row["song_id"] as String] = row["play_count"] as Int
            }
            return result
        }
    }

    /// Get the last played date for each song
    func lastPlayedDates(serverId: String) throws -> [String: Date] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT song_id, MAX(played_at) as last_played
                    FROM play_history
                    WHERE server_id = ?
                    GROUP BY song_id
                    """,
                arguments: [serverId]
            )
            var result: [String: Date] = [:]
            for row in rows {
                result[row["song_id"] as String] = row["last_played"] as Date
            }
            return result
        }
    }

    // MARK: - Starred Items

    /// Record a star action locally (parallel write alongside API call)
    func starItem(id: String, type: String, serverId: String, starredAt: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO starred_items (item_id, item_type, server_id, starred_at, unstarred_at)
                    VALUES (?, ?, ?, ?, NULL)
                    ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                        starred_at = excluded.starred_at,
                        unstarred_at = NULL
                    """,
                arguments: [id, type, serverId, starredAt]
            )
        }
    }

    /// Record an unstar action locally (soft delete — preserves history)
    func unstarItem(id: String, type: String, serverId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE starred_items SET unstarred_at = ?
                    WHERE item_id = ? AND item_type = ? AND server_id = ?
                    """,
                arguments: [Date(), id, type, serverId]
            )
        }
    }

    /// Load active starred item IDs of a given type, sorted by starred_at DESC
    func loadStarredIds(type: String, serverId: String) throws -> [(itemId: String, starredAt: Date)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT item_id, starred_at FROM starred_items
                    WHERE item_type = ? AND server_id = ? AND unstarred_at IS NULL
                    ORDER BY starred_at DESC
                    """,
                arguments: [type, serverId]
            )
            return rows.map { (itemId: $0["item_id"] as String, starredAt: $0["starred_at"] as Date) }
        }
    }

    /// Load starred songs from cached_songs, ordered by starred_at DESC from starred_items
    func loadStarredSongs(serverId: String) throws -> [Song] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM cached_songs s
                    INNER JOIN starred_items si
                        ON s.id = si.item_id AND si.item_type = 'song' AND si.server_id = ?
                    WHERE si.unstarred_at IS NULL AND s.server_id = ?
                    ORDER BY si.starred_at DESC
                    """,
                arguments: [serverId, serverId]
            )
            return rows.map { row in
                Song(
                    id: row["id"], title: row["title"], album: row["album_name"],
                    albumId: row["album_id"], artist: row["artist_name"],
                    artistId: row["artist_id"], track: row["track"],
                    discNumber: row["disc_number"], year: row["year"],
                    genre: row["genre"], duration: row["duration"],
                    bitRate: row["bit_rate"], contentType: row["content_type"],
                    suffix: row["suffix"], coverArt: row["cover_art_id"],
                    starred: row["starred_at"], rating: row["rating"]
                )
            }
        }
    }

    /// Load starred albums from cached_albums, ordered by starred_at DESC from starred_items
    func loadStarredAlbums(serverId: String) throws -> [Album] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM cached_albums a
                    INNER JOIN starred_items si
                        ON a.id = si.item_id AND si.item_type = 'album' AND si.server_id = ?
                    WHERE si.unstarred_at IS NULL AND a.server_id = ?
                    ORDER BY si.starred_at DESC
                    """,
                arguments: [serverId, serverId]
            )
            return rows.map { row in
                Album(
                    id: row["id"], name: row["name"], artist: row["artist_name"],
                    artistId: row["artist_id"], songCount: row["song_count"],
                    duration: row["duration"], year: row["year"], genre: row["genre"],
                    coverArt: row["cover_art_id"], starred: row["starred_at"],
                    rating: row["rating"]
                )
            }
        }
    }

    /// Load starred artists from cached_artists, ordered by starred_at DESC from starred_items
    func loadStarredArtists(serverId: String) throws -> [Artist] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM cached_artists a
                    INNER JOIN starred_items si
                        ON a.id = si.item_id AND si.item_type = 'artist' AND si.server_id = ?
                    WHERE si.unstarred_at IS NULL AND a.server_id = ?
                    ORDER BY si.starred_at DESC
                    """,
                arguments: [serverId, serverId]
            )
            return rows.map { row in
                Artist(
                    id: row["id"], name: row["name"],
                    albumCount: row["album_count"], coverArt: row["cover_art_id"],
                    starred: row["starred_at"]
                )
            }
        }
    }

    /// Sync starred items from API response — reconcile local db with server truth.
    /// Bootstraps on first run, then reconciles on subsequent syncs.
    func syncStarredFromAPI(songs: [Song], albums: [Album], artists: [Artist], serverId: String) throws {
        try dbPool.write { db in
            // Build sets of currently-starred IDs from API
            let apiStarredSongs = Set(songs.map { $0.id })
            let apiStarredAlbums = Set(albums.map { $0.id })
            let apiStarredArtists = Set(artists.map { $0.id })

            // Get locally-starred IDs (active only)
            let localRows = try Row.fetchAll(
                db,
                sql: "SELECT item_id, item_type FROM starred_items WHERE server_id = ? AND unstarred_at IS NULL",
                arguments: [serverId]
            )
            var localStarred: [String: Set<String>] = ["song": [], "album": [], "artist": []]
            for row in localRows {
                let type: String = row["item_type"]
                let id: String = row["item_id"]
                localStarred[type, default: []].insert(id)
            }

            // Upsert items starred on server but not locally
            func syncType(_ type: String, apiIds: Set<String>, items: [(id: String, starred: Date?)]) throws {
                for item in items {
                    let id = item.id
                    if !localStarred[type, default: []].contains(id) {
                        try db.execute(
                            sql: """
                                INSERT INTO starred_items (item_id, item_type, server_id, starred_at, unstarred_at)
                                VALUES (?, ?, ?, ?, NULL)
                                ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                                    starred_at = excluded.starred_at,
                                    unstarred_at = NULL
                                """,
                            arguments: [id, type, serverId, item.starred ?? Date()]
                        )
                    }
                }

                // Soft-delete items unstarred on server but still active locally
                for localId in localStarred[type, default: []] {
                    if !apiIds.contains(localId) {
                        try db.execute(
                            sql: "UPDATE starred_items SET unstarred_at = ? WHERE item_id = ? AND item_type = ? AND server_id = ? AND unstarred_at IS NULL",
                            arguments: [Date(), localId, type, serverId]
                        )
                    }
                }
            }

            try syncType("song", apiIds: apiStarredSongs,
                         items: songs.map { (id: $0.id, starred: $0.starred) })
            try syncType("album", apiIds: apiStarredAlbums,
                         items: albums.map { (id: $0.id, starred: $0.starred) })
            try syncType("artist", apiIds: apiStarredArtists,
                         items: artists.map { (id: $0.id, starred: $0.starred) })
        }
    }

    // MARK: - Hidden Items

    /// Hide an item (song, album, or artist)
    func hideItem(id: String, type: String, serverId: String, reason: String? = nil) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hidden_items (item_id, item_type, server_id, hidden_at, reason)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                        hidden_at = excluded.hidden_at,
                        reason = excluded.reason
                    """,
                arguments: [id, type, serverId, Date(), reason]
            )
        }
    }

    /// Unhide an item
    func unhideItem(id: String, type: String, serverId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM hidden_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
                arguments: [id, type, serverId]
            )
        }
    }

    /// Check if an item is hidden
    func isHidden(id: String, type: String, serverId: String) throws -> Bool {
        try dbPool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM hidden_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
                arguments: [id, type, serverId]
            )
            return (count ?? 0) > 0
        }
    }

    /// Load all hidden item IDs for a type
    func loadHiddenIds(type: String, serverId: String) throws -> Set<String> {
        try dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT item_id FROM hidden_items WHERE item_type = ? AND server_id = ?",
                arguments: [type, serverId]
            )
            return Set(ids)
        }
    }

    /// Load all hidden items (for settings/management UI)
    func loadHiddenItems(serverId: String) throws -> [(itemId: String, itemType: String, hiddenAt: Date, reason: String?)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM hidden_items WHERE server_id = ? ORDER BY hidden_at DESC",
                arguments: [serverId]
            )
            return rows.map { row in
                (
                    itemId: row["item_id"] as String,
                    itemType: row["item_type"] as String,
                    hiddenAt: row["hidden_at"] as Date,
                    reason: row["reason"] as String?
                )
            }
        }
    }

    /// Load hidden items with names resolved from cached tables
    func loadHiddenItemsWithNames(serverId: String) throws -> [(itemId: String, itemType: String, name: String, subtitle: String, hiddenAt: Date)] {
        try dbPool.read { db in
            // Albums
            let albumRows = try Row.fetchAll(db, sql: """
                SELECT h.item_id, h.item_type, h.hidden_at, a.name, a.artist_name
                FROM hidden_items h
                LEFT JOIN cached_albums a ON h.item_id = a.id
                WHERE h.server_id = ? AND h.item_type = 'album'
                ORDER BY h.hidden_at DESC
                """, arguments: [serverId])

            // Artists
            let artistRows = try Row.fetchAll(db, sql: """
                SELECT h.item_id, h.item_type, h.hidden_at, a.name
                FROM hidden_items h
                LEFT JOIN cached_artists a ON h.item_id = a.id
                WHERE h.server_id = ? AND h.item_type = 'artist'
                ORDER BY h.hidden_at DESC
                """, arguments: [serverId])

            // Songs
            let songRows = try Row.fetchAll(db, sql: """
                SELECT h.item_id, h.item_type, h.hidden_at, s.title, s.artist_name
                FROM hidden_items h
                LEFT JOIN cached_songs s ON h.item_id = s.id
                WHERE h.server_id = ? AND h.item_type = 'song'
                ORDER BY h.hidden_at DESC
                """, arguments: [serverId])

            var results: [(itemId: String, itemType: String, name: String, subtitle: String, hiddenAt: Date)] = []

            for row in albumRows {
                results.append((
                    itemId: row["item_id"] as String,
                    itemType: "album",
                    name: (row["name"] as String?) ?? "Unknown Album",
                    subtitle: (row["artist_name"] as String?) ?? "",
                    hiddenAt: row["hidden_at"] as Date
                ))
            }
            for row in artistRows {
                results.append((
                    itemId: row["item_id"] as String,
                    itemType: "artist",
                    name: (row["name"] as String?) ?? "Unknown Artist",
                    subtitle: "",
                    hiddenAt: row["hidden_at"] as Date
                ))
            }
            for row in songRows {
                results.append((
                    itemId: row["item_id"] as String,
                    itemType: "song",
                    name: (row["title"] as String?) ?? "Unknown Song",
                    subtitle: (row["artist_name"] as String?) ?? "",
                    hiddenAt: row["hidden_at"] as Date
                ))
            }

            return results.sorted { $0.hiddenAt > $1.hiddenAt }
        }
    }

    // MARK: - Liked Items (Resonance-only, not synced to navidrome)

    /// Like an item (local-only, separate from starred/loved)
    func likeItem(
        id: String,
        type: String,
        serverId: String,
        likedAt: Date = Date(),
        source: String? = "manual"
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO liked_items (item_id, item_type, server_id, liked_at, source)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                        liked_at = excluded.liked_at,
                        source = excluded.source
                    """,
                arguments: [id, type, serverId, likedAt, source]
            )
        }
    }

    /// Unlike an item (hard delete — no history needed for likes)
    func unlikeItem(id: String, type: String, serverId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM liked_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
                arguments: [id, type, serverId]
            )
        }
    }

    /// Check if an item is liked
    func isLiked(id: String, type: String, serverId: String) throws -> Bool {
        try dbPool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM liked_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
                arguments: [id, type, serverId]
            )
            return (count ?? 0) > 0
        }
    }

    /// Load liked item IDs for a type (for cached sets)
    func loadLikedIds(type: String, serverId: String) throws -> Set<String> {
        try dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT item_id FROM liked_items WHERE item_type = ? AND server_id = ?",
                arguments: [type, serverId]
            )
            return Set(ids)
        }
    }

    /// Load liked songs from cached_songs, ordered by liked_at DESC.
    /// Includes likedAt so callers can distinguish local likes from Navidrome loves.
    func loadLikedSongRows(serverId: String) throws -> [LikedSongRow] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        s.*,
                        li.server_id AS liked_server_id,
                        li.liked_at,
                        li.source,
                        COALESCE(si.starred_at, s.starred_at) AS compatibility_starred_at
                    FROM cached_songs s
                    INNER JOIN liked_items li
                        ON s.id = li.item_id AND li.item_type = 'song' AND li.server_id = ?
                    LEFT JOIN starred_items si
                        ON si.item_id = s.id
                        AND si.item_type = 'song'
                        AND si.server_id = s.server_id
                        AND si.unstarred_at IS NULL
                    WHERE s.server_id = ?
                    ORDER BY li.liked_at DESC
                    """,
                arguments: [serverId, serverId]
            )
            return rows.map { row in
                LikedSongRow(
                    song: Song(
                        id: row["id"], title: row["title"], album: row["album_name"],
                        albumId: row["album_id"], artist: row["artist_name"],
                        artistId: row["artist_id"], track: row["track"],
                        discNumber: row["disc_number"], year: row["year"],
                        genre: row["genre"], duration: row["duration"],
                        bitRate: row["bit_rate"], contentType: row["content_type"],
                        suffix: row["suffix"], coverArt: row["cover_art_id"],
                        starred: row["compatibility_starred_at"], rating: row["rating"]
                    ),
                    serverId: row["liked_server_id"],
                    source: row["source"],
                    likedAt: row["liked_at"]
                )
            }
        }
    }

    /// Import Navidrome song stars into local liked songs without removing or downgrading manual likes.
    /// This keeps Resonance's liked state canonical while preserving star compatibility.
    @discardableResult
    func importLikedSongsFromStarredSongs(
        _ songs: [Song],
        serverId: String,
        source: String = "navidrome_starred"
    ) throws -> Int {
        try dbPool.write { db in
            var insertedCount = 0

            for song in songs {
                let alreadyLiked = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM liked_items
                            WHERE item_id = ? AND item_type = 'song' AND server_id = ?
                        )
                        """,
                    arguments: [song.id, serverId]
                ) ?? false

                guard !alreadyLiked else { continue }

                try db.execute(
                    sql: """
                        INSERT INTO liked_items (item_id, item_type, server_id, liked_at, source)
                        VALUES (?, 'song', ?, ?, ?)
                        """,
                    arguments: [song.id, serverId, song.starred ?? Date(), source]
                )
                insertedCount += 1
            }

            return insertedCount
        }
    }

    /// Backward-compatible view of liked songs for existing callers that only need Song.
    func loadLikedSongs(serverId: String) throws -> [Song] {
        try loadLikedSongRows(serverId: serverId).map(\.song)
    }

    /// Load liked albums from cached_albums, ordered by liked_at DESC
    func loadLikedAlbums(serverId: String) throws -> [Album] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.* FROM cached_albums a
                    INNER JOIN liked_items li
                        ON a.id = li.item_id AND li.item_type = 'album' AND li.server_id = ?
                    WHERE a.server_id = ?
                    ORDER BY li.liked_at DESC
                    """,
                arguments: [serverId, serverId]
            )
            return rows.map { row in
                Album(
                    id: row["id"], name: row["name"], artist: row["artist_name"],
                    artistId: row["artist_id"], songCount: row["song_count"],
                    duration: row["duration"], year: row["year"], genre: row["genre"],
                    coverArt: row["cover_art_id"], starred: row["starred_at"],
                    rating: row["rating"]
                )
            }
        }
    }

    /// Bulk import liked items (for Apple Music Library.xml import)
    func bulkImportLikedItems(items: [(id: String, type: String, likedAt: Date, source: String)], serverId: String) throws {
        try dbPool.write { db in
            for item in items {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO liked_items (item_id, item_type, server_id, liked_at, source)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [item.id, item.type, serverId, item.likedAt, item.source]
                )
            }
        }
    }

    /// Bulk import starred/loved items (for Apple Music Library.xml import)
    func bulkImportStarredItems(items: [(id: String, type: String, starredAt: Date)], serverId: String) throws {
        try dbPool.write { db in
            for item in items {
                try db.execute(
                    sql: """
                        INSERT INTO starred_items (item_id, item_type, server_id, starred_at, unstarred_at)
                        VALUES (?, ?, ?, ?, NULL)
                        ON CONFLICT(item_id, item_type, server_id) DO UPDATE SET
                            starred_at = excluded.starred_at,
                            unstarred_at = NULL
                        """,
                    arguments: [item.id, item.type, serverId, item.starredAt]
                )
            }
        }
    }

    /// Bulk import play history (for Apple Music Library.xml import)
    func bulkImportPlayHistory(items: [(songId: String, playedAt: Date, count: Int, title: String, artist: String, album: String, albumId: String, coverArt: String?)], serverId: String) throws {
        try dbPool.write { db in
            for item in items {
                // Insert one entry per track with the last play date
                // (Apple Music only gives us last play date + total count, not individual plays)
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO play_history
                            (song_id, server_id, played_at, title, artist, album, album_id, cover_art)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.songId, serverId, item.playedAt,
                        item.title, item.artist, item.album, item.albumId, item.coverArt
                    ]
                )
            }
        }
    }

    // MARK: - Sync Metadata

    func setSyncMetadata(key: String, value: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_metadata (key, value, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                arguments: [key, value, Date()]
            )
        }
    }

    func getSyncMetadata(key: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_metadata WHERE key = ?",
                arguments: [key]
            )
        }
    }

    // MARK: - Smart Playlists

    /// Create or update a smart playlist
    func saveSmartPlaylist(_ playlist: SmartPlaylist) throws {
        let rulesJSON = try JSONEncoder().encode(playlist.ruleGroup)
        let rulesString = String(data: rulesJSON, encoding: .utf8) ?? "[]"

        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO smart_playlists
                        (id, name, server_id, rules_json, sort_by, sort_order, item_limit, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        rules_json = excluded.rules_json,
                        sort_by = excluded.sort_by,
                        sort_order = excluded.sort_order,
                        item_limit = excluded.item_limit,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    playlist.id, playlist.name, playlist.serverId, rulesString,
                    playlist.sortBy, playlist.sortOrder.rawValue, playlist.itemLimit,
                    playlist.createdAt, Date()
                ]
            )
        }
    }

    /// Delete a smart playlist and its cached results
    func deleteSmartPlaylist(id: String) throws {
        try dbPool.write { db in
            // Results cascade-delete via foreign key
            try db.execute(sql: "DELETE FROM smart_playlists WHERE id = ?", arguments: [id])
        }
    }

    /// Load all smart playlists for a server
    func loadSmartPlaylists(serverId: String) throws -> [SmartPlaylist] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM smart_playlists WHERE server_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverId]
            )
            return rows.compactMap { row -> SmartPlaylist? in
                guard let rulesString = row["rules_json"] as? String,
                      let rulesData = rulesString.data(using: .utf8),
                      let ruleGroup = try? JSONDecoder().decode(SmartPlaylistRuleGroup.self, from: rulesData) else {
                    return nil
                }
                return SmartPlaylist(
                    id: row["id"],
                    name: row["name"],
                    serverId: row["server_id"],
                    ruleGroup: ruleGroup,
                    sortBy: row["sort_by"] ?? "title",
                    sortOrder: SmartPlaylist.SortOrder(rawValue: row["sort_order"] ?? "asc") ?? .asc,
                    itemLimit: row["item_limit"]
                )
            }
        }
    }

    /// Evaluate a smart playlist: run compiled SQL, cache results, return song IDs
    @discardableResult
    func evaluateSmartPlaylist(_ playlist: SmartPlaylist) throws -> [String] {
        let query = SmartPlaylistCompiler.buildEvaluationQuery(playlist: playlist)

        return try dbPool.write { db in
            // Run the compiled query to get matching song IDs
            let songIds = try String.fetchAll(db, sql: query.sql, arguments: StatementArguments(query.arguments))

            // Clear old results
            try db.execute(
                sql: "DELETE FROM smart_playlist_results WHERE playlist_id = ?",
                arguments: [playlist.id]
            )

            // Cache new results
            for (position, songId) in songIds.enumerated() {
                try db.execute(
                    sql: "INSERT INTO smart_playlist_results (playlist_id, song_id, position) VALUES (?, ?, ?)",
                    arguments: [playlist.id, songId, position]
                )
            }

            // Update last_evaluated timestamp
            try db.execute(
                sql: "UPDATE smart_playlists SET last_evaluated = ? WHERE id = ?",
                arguments: [Date(), playlist.id]
            )

            return songIds
        }
    }

    /// Load songs for a smart playlist from cached results (fast, no re-evaluation)
    func loadSmartPlaylistSongs(playlistId: String, serverId: String) throws -> [Song] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM cached_songs s
                    INNER JOIN smart_playlist_results spr ON s.id = spr.song_id
                    WHERE spr.playlist_id = ? AND s.server_id = ?
                    ORDER BY spr.position ASC
                    """,
                arguments: [playlistId, serverId]
            )
            return rows.map { row in
                Song(
                    id: row["id"], title: row["title"], album: row["album_name"],
                    albumId: row["album_id"], artist: row["artist_name"],
                    artistId: row["artist_id"], track: row["track"],
                    discNumber: row["disc_number"], year: row["year"],
                    genre: row["genre"], duration: row["duration"],
                    bitRate: row["bit_rate"], contentType: row["content_type"],
                    suffix: row["suffix"], coverArt: row["cover_art_id"],
                    starred: row["starred_at"], rating: row["rating"]
                )
            }
        }
    }

    /// Get the count of matching songs for a smart playlist (for preview)
    func smartPlaylistMatchCount(_ playlist: SmartPlaylist) throws -> Int {
        let query = SmartPlaylistCompiler.buildEvaluationQuery(playlist: playlist)
        // Wrap in a COUNT query
        let countSQL = "SELECT COUNT(*) FROM (\(query.sql))"
        return try dbPool.read { db in
            try Int.fetchOne(db, sql: countSQL, arguments: StatementArguments(query.arguments)) ?? 0
        }
    }

    // MARK: - Discovery Feed

    /// Record newly discovered albums (diff from library sync)
    func recordDiscoveredAlbums(_ albumIds: [String], serverId: String) throws {
        guard !albumIds.isEmpty else { return }
        try dbPool.write { db in
            for albumId in albumIds {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO discovered_albums
                            (album_id, server_id, discovered_at, is_seen)
                        VALUES (?, ?, ?, 0)
                        """,
                    arguments: [albumId, serverId, Date()]
                )
            }
        }
    }

    /// Load discovered albums with full album data, ordered by discovered_at DESC
    func loadDiscoveredAlbums(serverId: String, unseenOnly: Bool = false) throws -> [(album: Album, discoveredAt: Date, isSeen: Bool)] {
        try dbPool.read { db in
            let seenFilter = unseenOnly ? "AND d.is_seen = 0" : ""
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.*, d.discovered_at, d.is_seen
                    FROM discovered_albums d
                    INNER JOIN cached_albums a ON d.album_id = a.id AND a.server_id = d.server_id
                    LEFT JOIN hidden_items hi ON a.id = hi.item_id AND hi.item_type = 'album' AND hi.server_id = d.server_id
                    WHERE d.server_id = ? AND hi.item_id IS NULL \(seenFilter)
                    ORDER BY d.discovered_at DESC
                    """,
                arguments: [serverId]
            )
            return rows.map { row in
                let album = Album(
                    id: row["id"], name: row["name"], artist: row["artist_name"],
                    artistId: row["artist_id"], songCount: row["song_count"],
                    duration: row["duration"], year: row["year"], genre: row["genre"],
                    coverArt: row["cover_art_id"], starred: row["starred_at"],
                    rating: row["rating"]
                )
                return (album: album, discoveredAt: row["discovered_at"] as Date, isSeen: row["is_seen"] as Bool)
            }
        }
    }

    /// Count unseen discovered albums
    func unseenDiscoveryCount(serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM discovered_albums d
                    LEFT JOIN hidden_items hi ON d.album_id = hi.item_id AND hi.item_type = 'album' AND hi.server_id = d.server_id
                    WHERE d.server_id = ? AND d.is_seen = 0 AND hi.item_id IS NULL
                    """,
                arguments: [serverId]
            ) ?? 0
        }
    }

    /// Mark all discoveries as seen
    func markAllDiscoveriesSeen(serverId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE discovered_albums SET is_seen = 1 WHERE server_id = ? AND is_seen = 0",
                arguments: [serverId]
            )
        }
    }

    /// Mark a single discovered album seen (NM-2 per-album Growing Edge clear —
    /// the persistent counterpart to the ledger's in-memory Mark-Seen). Idempotent
    /// and a no-op when the album isn't a tracked (unseen) discovery.
    func markDiscoverySeen(albumId: String, serverId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE discovered_albums SET is_seen = 1 WHERE album_id = ? AND server_id = ? AND is_seen = 0",
                arguments: [albumId, serverId]
            )
        }
    }

    /// Ledger `source` tag for the bounded seed of albums that were already in
    /// the library before Resonance started watching. Real arrivals recorded by
    /// a refresh diff carry no source.
    static let discoveryBackfillSource = "backfill"

    /// Discovery ledger rows carrying their `source` tag, so the New Music room
    /// can separate genuine arrivals from the pre-history backfill seed.
    /// Same shape and filtering as `loadDiscoveredAlbums`, plus the tag.
    func loadDiscoveryLedger(serverId: String) throws -> [(album: Album, discoveredAt: Date, isSeen: Bool, source: String?)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.*, d.discovered_at, d.is_seen, d.source AS discovery_source
                    FROM discovered_albums d
                    INNER JOIN cached_albums a ON d.album_id = a.id AND a.server_id = d.server_id
                    LEFT JOIN hidden_items hi ON a.id = hi.item_id AND hi.item_type = 'album' AND hi.server_id = d.server_id
                    WHERE d.server_id = ? AND hi.item_id IS NULL
                    ORDER BY d.discovered_at DESC
                    """,
                arguments: [serverId]
            )
            return rows.map { row in
                let album = Album(
                    id: row["id"], name: row["name"], artist: row["artist_name"],
                    artistId: row["artist_id"], songCount: row["song_count"],
                    duration: row["duration"], year: row["year"], genre: row["genre"],
                    coverArt: row["cover_art_id"], starred: row["starred_at"],
                    rating: row["rating"]
                )
                return (
                    album: album,
                    discoveredAt: row["discovered_at"] as Date,
                    isSeen: row["is_seen"] as Bool,
                    source: row["discovery_source"] as String?
                )
            }
        }
    }

    /// Whether this server has any discovery rows at all (seeded or real) — the
    /// gate for the one-time backfill so it never re-seeds a used ledger.
    func hasDiscoveryHistory(serverId: String) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM discovered_albums WHERE server_id = ?)",
                arguments: [serverId]
            ) ?? false
        }
    }

    /// Seed the ledger with up to `limit` albums that predate Resonance's
    /// watching, newest first, tagged `discoveryBackfillSource` and already
    /// seen so nothing glows retroactively. Rows whose album isn't cached are
    /// simply dropped by the display JOIN. Returns the number of rows inserted.
    @discardableResult
    func backfillDiscoveredAlbums(_ albumIds: [String], serverId: String, limit: Int = 50) throws -> Int {
        let bounded = Array(albumIds.prefix(limit))
        guard !bounded.isEmpty else { return 0 }
        let now = Date()
        return try dbPool.write { db in
            var inserted = 0
            for (index, albumId) in bounded.enumerated() {
                // Stagger stamps a second apart so the caller's newest-first
                // order survives `ORDER BY discovered_at DESC`.
                let stamp = now.addingTimeInterval(-Double(index))
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO discovered_albums
                            (album_id, server_id, discovered_at, source, is_seen)
                        VALUES (?, ?, ?, ?, 1)
                        """,
                    arguments: [albumId, serverId, stamp, Self.discoveryBackfillSource]
                )
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// Cache-side fallback source for the backfill. `cached_albums` has no true
    /// added-at column (`last_fetched` is rewritten on every sync), so release
    /// year is the closest honest recency proxy when the server's `newest` list
    /// isn't reachable.
    func recentCachedAlbumIds(serverId: String, limit: Int) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM cached_albums
                    WHERE server_id = ?
                    ORDER BY COALESCE(year, 0) DESC, name ASC
                    LIMIT ?
                    """,
                arguments: [serverId, limit]
            )
        }
    }

    /// Get album IDs already known in the cache (for diff detection)
    func cachedAlbumCount(serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cached_albums WHERE server_id = ?", arguments: [serverId]) ?? 0
        }
    }

    func cachedSongCount(serverId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cached_songs WHERE server_id = ?", arguments: [serverId]) ?? 0
        }
    }

    func knownAlbumIds(serverId: String) throws -> Set<String> {
        try dbPool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM cached_albums WHERE server_id = ?",
                arguments: [serverId]
            )
            return Set(ids)
        }
    }

    // MARK: - Management Requests (Companion Service IPC)

    /// Create a management request for the companion service
    @discardableResult
    func createMgmtRequest(type: String, payload: String) throws -> String {
        let requestId = UUID().uuidString
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mgmt_requests (id, type, payload_json, status, created_at)
                    VALUES (?, ?, ?, 'pending', ?)
                    """,
                arguments: [requestId, type, payload, Date()]
            )
        }
        return requestId
    }

    /// Check the status/result of a management request
    func checkMgmtResult(requestId: String) throws -> (status: String, result: String?, error: String?) {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT status, result_json, error_message FROM mgmt_requests WHERE id = ?",
                arguments: [requestId]
            ) else {
                return (status: "not_found", result: nil, error: nil)
            }
            return (
                status: row["status"] as String,
                result: row["result_json"] as String?,
                error: row["error_message"] as String?
            )
        }
    }

    /// Clean up old completed/failed requests (older than 7 days)
    func cleanupOldMgmtRequests() throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    DELETE FROM mgmt_requests
                    WHERE status IN ('completed', 'failed')
                    AND completed_at < datetime('now', '-7 days')
                    """
            )
        }
    }

    // MARK: - Migration helpers

    /// Migrate play history from UserDefaults (call once on first launch after upgrade)
    func migratePlayHistoryFromUserDefaults(serverId: String) throws {
        let storageKey = "playHistory"
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }

        // Decode using the same format as PlayHistoryStore
        struct LegacyPlayedItem: Codable {
            let id: String
            let playedAt: Date
            let title: String
            let artist: String
            let album: String
            let albumId: String
            let coverArt: String?
            let duration: Int?
        }

        guard let items = try? JSONDecoder().decode([LegacyPlayedItem].self, from: data) else { return }
        guard !items.isEmpty else { return }

        try dbPool.write { db in
            for item in items {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO play_history
                            (song_id, server_id, played_at, title, artist, album, album_id, cover_art)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id, serverId, item.playedAt,
                        item.title, item.artist, item.album, item.albumId, item.coverArt
                    ]
                )
            }
        }

        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Source Attribution (Fetcher provenance)

    /// Bulk, idempotent upsert of Fetcher source-attribution rows keyed by
    /// `file_path`. V2 rows persist Fetcher's exact Navidrome song identity;
    /// importing an older v1 snapshot does not erase a previously known id.
    /// Rows with a blank `local_path` remain invalid contract rows and are
    /// skipped.
    func upsertSourceAttributions(_ rows: [FetcherSourceAttribution]) throws {
        guard !rows.isEmpty else { return }
        let importedAt = ISO8601DateFormatter().string(from: Date())

        try dbPool.write { db in
            for row in rows {
                let filePath = row.localPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !filePath.isEmpty else { continue }
                let matchKey = PathMatchKey.canonical(filePath)
                let trimmedSongId = row.navidromeSongId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let navidromeSongId = trimmedSongId?.isEmpty == false ? trimmedSongId : nil

                // Preserve-by-default means a genuine un-resolution cannot clear
                // an id here; that is safest until resolver failures are proven,
                // but a future explicit reset path is still owed.
                try db.execute(
                    sql: """
                        INSERT INTO source_attribution
                            (file_path, match_key, navidrome_song_id, attribution_key,
                             source_collection_key, source_kind,
                             source_display_name, download_source, query_context, acquired_at, imported_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(file_path) DO UPDATE SET
                            match_key = excluded.match_key,
                            navidrome_song_id = CASE
                                WHEN ? AND excluded.navidrome_song_id IS NOT NULL
                                    THEN excluded.navidrome_song_id
                                ELSE source_attribution.navidrome_song_id
                            END,
                            attribution_key = excluded.attribution_key,
                            source_collection_key = excluded.source_collection_key,
                            source_kind = excluded.source_kind,
                            source_display_name = excluded.source_display_name,
                            download_source = excluded.download_source,
                            query_context = excluded.query_context,
                            acquired_at = excluded.acquired_at,
                            imported_at = excluded.imported_at
                    """,
                    arguments: [
                        filePath, matchKey, navidromeSongId, row.attributionKey,
                        row.sourceCollectionKey, row.sourceKind,
                        row.sourceDisplayName, row.downloadSource, row.queryContext,
                        row.acquiredAt, importedAt, row.contractVersion >= 2
                    ]
                )
            }
        }
    }

    /// Exact-match provenance lookup by stored absolute `file_path`.
    func sourceAttribution(forPath path: String) throws -> SourceAttributionRecord? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_attribution WHERE file_path = ?",
                arguments: [trimmed]
            ).map(SourceAttributionRecord.init(row:))
        }
    }

    /// Primary provenance lookup. Fetcher v2 publishes Navidrome's
    /// `media_file.id`, which is byte-identical to `Song.id`.
    func sourceAttribution(forSongId songId: String) throws -> SourceAttributionRecord? {
        let trimmed = songId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM source_attribution
                    WHERE navidrome_song_id = ?
                    ORDER BY acquired_at DESC, file_path
                    LIMIT 1
                    """,
                arguments: [trimmed]
            ).map(SourceAttributionRecord.init(row:))
        }
    }

    /// Tolerant provenance lookup joining Navidrome's music-folder-relative `path`
    /// to the fetcher's absolute `local_path`. Resolution is exact first, then an
    /// indexed canonical-key equality lookup. Only a key collision, an
    /// underspecified legacy query, or a NULL-key row invokes component-level
    /// suffix comparison.
    func sourceAttribution(matchingSuffixOf path: String) throws -> SourceAttributionRecord? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return try dbPool.read { db in
            if let exact = try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_attribution WHERE file_path = ?",
                arguments: [trimmed]
            ).map(SourceAttributionRecord.init(row:)) {
                return exact
            }

            if let matchKey = PathMatchKey.canonical(trimmed) {
                var candidates = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM source_attribution WHERE match_key = ? ORDER BY file_path",
                    arguments: [matchKey]
                ).map(SourceAttributionRecord.init(row:))
                if candidates.isEmpty, Self.isUnderspecifiedMatchPath(trimmed) {
                    // A one/two-component legacy query cannot equal a stored
                    // three-component key. Treat that deliberately as genuine
                    // ambiguity and suffix-filter only its candidate keys.
                    candidates = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM source_attribution
                            WHERE match_key LIKE ? ESCAPE '\\'
                            ORDER BY file_path
                            """,
                        arguments: ["%/\(Self.escapedLikePattern(matchKey))"]
                    ).map(SourceAttributionRecord.init(row:))
                }
                if candidates.count == 1 {
                    return candidates[0]
                }
                if let collisionWinner = Self.bestFullSuffixMatch(
                    forPath: trimmed,
                    candidates: candidates
                ) {
                    return collisionWinner
                }
            }

            // v8 backfills every usable path. NULL is therefore an explicit
            // legacy/degenerate escape hatch, not a scan of the full table.
            let legacyRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM source_attribution WHERE match_key IS NULL ORDER BY file_path"
            ).map(SourceAttributionRecord.init(row:))
            return Self.bestFullSuffixMatch(forPath: trimmed, candidates: legacyRows)
        }
    }

    /// Batch provenance lookup keyed by exact Navidrome song id. Song paths are
    /// deliberately ignored: Subsonic synthesizes them from tags and they do
    /// not identify Fetcher's local files.
    func sourceAttributionsBySongId(songs: [Song]) throws -> [String: SourceAttributionRecord] {
        let songIds = Array(Set(songs.compactMap { song -> String? in
            let trimmed = song.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
        guard !songIds.isEmpty else { return [:] }

        return try dbPool.read { db in
            var result: [String: SourceAttributionRecord] = [:]
            try Self.forEachChunk(songIds) { chunk in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM source_attribution
                        WHERE navidrome_song_id IN (\(Self.placeholders(chunk.count)))
                        ORDER BY navidrome_song_id, acquired_at DESC, file_path
                        """,
                    arguments: StatementArguments(chunk)
                ).map(SourceAttributionRecord.init(row:))
                for row in rows {
                    guard let songId = row.navidromeSongId,
                          result[songId] == nil
                    else { continue }
                    result[songId] = row
                }
            }
            return result
        }
    }

    /// Inverse of `sourceAttributionsBySongId`: cached Navidrome song ids grouped
    /// by the Fetcher collection that supplied them. The join is the exact
    /// `cached_songs.id = source_attribution.navidrome_song_id` identity bridge.
    /// Rows without a collection key are ignored because they cannot name a
    /// collection to project.
    func songIdsBySourceCollectionKey(serverId: String) throws -> [String: [String]] {
        let rows = try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT cached_songs.id AS song_id,
                           source_attribution.source_collection_key,
                           source_attribution.acquired_at,
                           source_attribution.file_path
                    FROM cached_songs
                    JOIN source_attribution
                      ON source_attribution.navidrome_song_id = cached_songs.id
                    WHERE cached_songs.server_id = ?
                      AND source_attribution.source_collection_key IS NOT NULL
                      AND source_attribution.source_collection_key != ''
                    """,
                arguments: [serverId]
            )
        }
        guard !rows.isEmpty else { return [:] }

        var matches: [String: [String: (acquiredAt: String, path: String)]] = [:]
        for row in rows {
            let collectionKey: String = row["source_collection_key"]
            let songId: String = row["song_id"]
            let candidate = (
                acquiredAt: (row["acquired_at"] as String?) ?? "",
                path: row["file_path"] as String
            )
            if let existing = matches[collectionKey]?[songId],
               (existing.acquiredAt, existing.path) >= (candidate.acquiredAt, candidate.path) {
                continue
            }
            matches[collectionKey, default: [:]][songId] = candidate
        }

        return matches.mapValues { entries in
            entries
                .map { (songId: $0.key, acquiredAt: $0.value.acquiredAt, path: $0.value.path) }
                .sorted {
                    ($0.acquiredAt, $0.path, $0.songId)
                        < ($1.acquiredAt, $1.path, $1.songId)
                }
                .map(\.songId)
        }
    }

    /// Number of distinct songs cleared from Unclassified since local midnight.
    func unclassifiedClearedTodayCount(serverId: String) throws -> Int {
        let localMidnight = Calendar.current.startOfDay(for: Date())
        return try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM (
                        SELECT song_id AS item_id
                        FROM waiting_room_items
                        WHERE server_id = ?
                          AND source LIKE 'unclassified%'
                          AND (added_at >= ? OR updated_at >= ?)
                        UNION
                        SELECT item_id
                        FROM hidden_items
                        WHERE server_id = ?
                          AND reason = 'unclassified_reject'
                          AND hidden_at >= ?
                    )
                    """,
                arguments: [
                    serverId, localMidnight, localMidnight,
                    serverId, localMidnight
                ]
            ) ?? 0
        }
    }

    /// Album-level provenance: distinct source voices behind an album's songs,
    /// joined by exact Navidrome song id and deduplicated by collection.
    ///
    /// The Arrivals Ledger UI consumes this exact signature. Do not rename.
    func sourceVoices(forAlbumId albumId: String) throws -> [SourceAttributionRecord] {
        let trimmedAlbumId = albumId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbumId.isEmpty else { return [] }

        // Delegate to the bulk path so the two APIs share one resolution core and
        // cannot drift. For a single album this is exactly the former inline body.
        return try sourceVoicesByAlbum(forAlbumIds: [trimmedAlbumId])[trimmedAlbumId] ?? []
    }

    /// Voice ordering: acquired_at descending, NULLs last, ties broken by
    /// file_path ascending for determinism. `acquired_at` is stored as an
    /// ISO-8601 string, which sorts lexicographically in chronological order.
    static func sourceVoiceOrdersBefore(_ lhs: SourceAttributionRecord, _ rhs: SourceAttributionRecord) -> Bool {
        switch (lhs.acquiredAt, rhs.acquiredAt) {
        case let (l?, r?):
            if l != r { return l > r }
            return lhs.filePath < rhs.filePath
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.filePath < rhs.filePath
        }
    }

    /// Bulk album-level curation state for One Plane tiles: attention mark,
    /// play count, and audition status for many albums in one call, keyed by
    /// album id. Albums with no state at all are omitted.
    ///
    /// OP-2: one read resolves every requested album's tile state. Signal by
    /// signal: attention marks aggregate the album's songs' active loved/
    /// interesting marks plus any album-level mark (loved outranks interesting,
    /// nil when neither); `playCount` sums play-history rows whose stored
    /// `album_id` is the album; `onAudition` is true when any of the album's
    /// songs sit in the Waiting Room in an unheard or interesting state (not
    /// admitted/rejected). Album ids are matched globally, mirroring
    /// `sourceVoicesByAlbum`. Albums with no signal at all are omitted.
    /// Signature pinned — the UI lane consumes it. Do not rename.
    func planeDecorations(forAlbumIds albumIds: [String]) throws -> [String: PlaneAlbumDecoration] {
        // Trim, drop blanks, and dedup while preserving determinism.
        var seen = Set<String>()
        var requestedIds: [String] = []
        for id in albumIds {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            requestedIds.append(trimmed)
        }
        guard !requestedIds.isEmpty else { return [:] }

        // Single read: build the song→album map for the requested albums, then
        // resolve each signal against it. Every IN list is chunked to stay under
        // SQLite's bound-variable limit (999 per chunk is safe).
        let (lovedAlbums, interestingAlbums, playByAlbum, auditionAlbums, discoveryByAlbum) = try dbPool.read {
            db -> (Set<String>, Set<String>, [String: Int], Set<String>, [String: (discoveredAt: Date, isSeen: Bool)]) in

            // 1. Map every requested album's songs to their album id.
            var albumForSong: [String: String] = [:]
            var songIds: [String] = []
            try Self.forEachChunk(requestedIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, album_id FROM cached_songs WHERE album_id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let songId: String = row["id"]
                    let albumId: String = row["album_id"]
                    albumForSong[songId] = albumId
                    songIds.append(songId)
                }
            }

            // 2. Active loved/interesting marks, collected per album. Album-level
            // marks key directly by the album id; song-level marks map up through
            // albumForSong. The loved-outranks-interesting choice is applied at
            // assembly, so both sets are populated independently here.
            var lovedAlbums = Set<String>()
            var interestingAlbums = Set<String>()
            func collect(_ albumId: String, _ markType: String) {
                if markType == AttentionMarkType.loved.rawValue {
                    lovedAlbums.insert(albumId)
                } else if markType == AttentionMarkType.interesting.rawValue {
                    interestingAlbums.insert(albumId)
                }
            }
            try Self.forEachChunk(requestedIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item_id, mark_type FROM attention_marks
                        WHERE item_type = ? AND cleared_at IS NULL
                          AND mark_type IN (?, ?)
                          AND item_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(
                        [LibraryItemType.album.rawValue,
                         AttentionMarkType.loved.rawValue,
                         AttentionMarkType.interesting.rawValue]
                        + Array(chunk)
                    )
                )
                for row in rows {
                    let albumId: String = row["item_id"]
                    let markType: String = row["mark_type"]
                    collect(albumId, markType)
                }
            }
            try Self.forEachChunk(songIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item_id, mark_type FROM attention_marks
                        WHERE item_type = ? AND cleared_at IS NULL
                          AND mark_type IN (?, ?)
                          AND item_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(
                        [LibraryItemType.song.rawValue,
                         AttentionMarkType.loved.rawValue,
                         AttentionMarkType.interesting.rawValue]
                        + Array(chunk)
                    )
                )
                for row in rows {
                    let songId: String = row["item_id"]
                    guard let albumId = albumForSong[songId] else { continue }
                    let markType: String = row["mark_type"]
                    collect(albumId, markType)
                }
            }

            // 3. Play counts by album. Each play row carries the album_id of the
            // song played, so the album-level count is a direct GROUP BY.
            var playByAlbum: [String: Int] = [:]
            try Self.forEachChunk(requestedIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT album_id, COUNT(*) AS play_count FROM play_history
                        WHERE album_id IN (\(placeholders))
                        GROUP BY album_id
                        """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let albumId: String = row["album_id"]
                    playByAlbum[albumId] = row["play_count"]
                }
            }

            // 4. On-audition membership: any of the album's songs in an unheard
            // or interesting waiting-room state (admitted/rejected are settled).
            var auditionAlbums = Set<String>()
            try Self.forEachChunk(songIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT song_id FROM waiting_room_items
                        WHERE state IN (?, ?) AND song_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(
                        [WaitingRoomState.unheard.rawValue,
                         WaitingRoomState.interesting.rawValue]
                        + Array(chunk)
                    )
                )
                for row in rows {
                    let songId: String = row["song_id"]
                    if let albumId = albumForSong[songId] {
                        auditionAlbums.insert(albumId)
                    }
                }
            }

            // 5. Growing Edge freshness (NM-2): discovery timestamp + seen flag
            // per album, keyed by album id. Server-agnostic like the signals
            // above; if the same album id appears under multiple servers, an
            // unseen row wins over a seen one, then the more recent discovery.
            var discoveryByAlbum: [String: (discoveredAt: Date, isSeen: Bool)] = [:]
            try Self.forEachChunk(requestedIds) { chunk in
                let placeholders = Self.placeholders(chunk.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT album_id, discovered_at, is_seen FROM discovered_albums WHERE album_id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let albumId: String = row["album_id"]
                    let discoveredAt: Date = row["discovered_at"]
                    let isSeen: Bool = row["is_seen"]
                    if let existing = discoveryByAlbum[albumId] {
                        let preferNew = (existing.isSeen && !isSeen)
                            || (existing.isSeen == isSeen && discoveredAt > existing.discoveredAt)
                        if preferNew { discoveryByAlbum[albumId] = (discoveredAt, isSeen) }
                    } else {
                        discoveryByAlbum[albumId] = (discoveredAt, isSeen)
                    }
                }
            }

            return (lovedAlbums, interestingAlbums, playByAlbum, auditionAlbums, discoveryByAlbum)
        }

        // Assemble, omitting albums with no signal at all. Loved outranks
        // interesting for the single displayed mark.
        var result: [String: PlaneAlbumDecoration] = [:]
        for albumId in requestedIds {
            let mark: String? = lovedAlbums.contains(albumId)
                ? AttentionMarkType.loved.rawValue
                : (interestingAlbums.contains(albumId) ? AttentionMarkType.interesting.rawValue : nil)
            let playCount = playByAlbum[albumId] ?? 0
            let onAudition = auditionAlbums.contains(albumId)
            let discovery = discoveryByAlbum[albumId]
            // An *unseen* discovery is a signal on its own (the Growing Edge glow);
            // a seen, otherwise-blank discovery renders nothing, so it stays omitted
            // to keep the decoration dict lean, matching the rest of this pass.
            let isUnseenDiscovery = discovery.map { !$0.isSeen } ?? false
            guard mark != nil || playCount != 0 || onAudition || isUnseenDiscovery else { continue }
            result[albumId] = PlaneAlbumDecoration(
                mark: mark,
                playCount: playCount,
                onAudition: onAudition,
                discoveredAt: discovery?.discoveredAt,
                isSeenDiscovery: discovery?.isSeen ?? false
            )
        }
        return result
    }

    /// Runs `body` over `ids` in chunks that stay under SQLite's bound-variable
    /// limit (999 is safe). Empty input runs `body` zero times.
    private static func forEachChunk(
        _ ids: [String],
        chunkSize: Int = 999,
        _ body: (ArraySlice<String>) throws -> Void
    ) rethrows {
        var index = 0
        while index < ids.count {
            let end = min(index + chunkSize, ids.count)
            try body(ids[index..<end])
            index = end
        }
    }

    /// A comma-separated run of `count` `?` placeholders for an IN list.
    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Bulk album-level provenance for the One Plane lanes: source voices for
    /// many albums in one call, keyed by album id. Albums resolving to no
    /// voices are omitted from the result.
    ///
    /// One read joins requested cached albums directly to attribution rows on
    /// exact Navidrome song id. IN lists are chunked under SQLite's variable
    /// limit. This is the shared core `sourceVoices(forAlbumId:)` delegates to,
    /// so for any album id
    /// `sourceVoicesByAlbum(...)[id] ?? [] == sourceVoices(forAlbumId: id)`.
    /// Signature is pinned — the UI lane consumes it. Do not rename.
    func sourceVoicesByAlbum(forAlbumIds albumIds: [String]) throws -> [String: [SourceAttributionRecord]] {
        // Trim, drop blanks, and dedup while preserving determinism.
        var seen = Set<String>()
        var requestedIds: [String] = []
        for id in albumIds {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            requestedIds.append(trimmed)
        }
        guard !requestedIds.isEmpty else { return [:] }

        let matchedByAlbum = try dbPool.read { db in
            var matchedByAlbum: [String: [SourceAttributionRecord]] = [:]
            try Self.forEachChunk(requestedIds) { chunk in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT cached_songs.album_id AS resolved_album_id,
                               source_attribution.*
                        FROM cached_songs
                        JOIN source_attribution
                          ON source_attribution.navidrome_song_id = cached_songs.id
                        WHERE cached_songs.album_id IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let albumId: String = row["resolved_album_id"]
                    matchedByAlbum[albumId, default: []].append(
                        SourceAttributionRecord(row: row)
                    )
                }
            }
            return matchedByAlbum
        }

        var result: [String: [SourceAttributionRecord]] = [:]
        for (albumId, matched) in matchedByAlbum {
            let voices = Self.dedupAndOrderVoices(matched)
            if !voices.isEmpty {
                result[albumId] = voices
            }
        }
        return result
    }

    private static func isUnderspecifiedMatchPath(_ path: String) -> Bool {
        let count = normalizedPathComponents(path).count
        return count > 0 && count < PathMatchKey.defaultComponentCount
    }

    private static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func bestFullSuffixMatch(
        forPath rawPath: String,
        candidates: [SourceAttributionRecord]
    ) -> SourceAttributionRecord? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryComponents = Self.normalizedPathComponents(trimmed)
        guard !queryComponents.isEmpty else { return nil }

        var best: SourceAttributionRecord?
        var bestMatch = 0
        for candidate in candidates {
            let candidateComponents = Self.normalizedPathComponents(candidate.filePath)
            let match = Self.commonSuffixLength(queryComponents, candidateComponents)
            guard match > 0,
                  match == min(queryComponents.count, candidateComponents.count)
            else { continue }
            if match > bestMatch || (match == bestMatch && candidate.filePath < (best?.filePath ?? "")) {
                bestMatch = match
                best = candidate
            }
        }
        return best
    }

    /// Collapses resolved voices to one representative per source: deduplicate by
    /// `source_collection_key` (falling back to `file_path` identity when a
    /// record carries no collection key, so distinct unattributed sources stay
    /// distinct), keeping the most-recently-acquired representative, then order
    /// by `sourceVoiceOrdersBefore`.
    private static func dedupAndOrderVoices(_ matched: [SourceAttributionRecord]) -> [SourceAttributionRecord] {
        var byKey: [String: SourceAttributionRecord] = [:]
        for record in matched {
            let key = record.sourceCollectionKey ?? "\u{1}filepath:\(record.filePath)"
            if let existing = byKey[key], Self.sourceVoiceOrdersBefore(existing, record) {
                continue
            }
            byKey[key] = record
        }
        return byKey.values.sorted(by: Self.sourceVoiceOrdersBefore)
    }

    /// Canonical components used only for collision/legacy suffix ranking.
    static func normalizedPathComponents(_ path: String) -> [String] {
        guard let canonical = PathMatchKey.canonical(path, components: .max) else {
            return []
        }
        return canonical.split(separator: "/").map(String.init)
    }

    /// Number of trailing components two component lists share.
    static func commonSuffixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        var i = lhs.count - 1
        var j = rhs.count - 1
        var count = 0
        while i >= 0, j >= 0, lhs[i] == rhs[j] {
            i -= 1
            j -= 1
            count += 1
        }
        return count
    }
}

// MARK: - Supporting types

/// Album-level curation state rendered on One Plane tiles (OP-2).
struct PlaneAlbumDecoration: Sendable, Equatable {
    /// "loved" or "interesting" (loved outranks); nil when unmarked.
    var mark: String?
    /// Total plays across the album's songs (wear derives from this in the UI).
    var playCount: Int
    /// True when any of the album's songs sit in the Waiting Room as
    /// unheard/interesting — the Salon projection ("on audition").
    var onAudition: Bool
    /// When this album was first detected as a new arrival (NM-2 Growing Edge);
    /// nil when it isn't a tracked discovery. `PlaneFreshness` turns this into a
    /// decaying glow intensity.
    var discoveredAt: Date? = nil
    /// True once the arrival has been seen — the glow and unseen dot clear at
    /// once (see `PlaneFreshness.intensity`).
    var isSeenDiscovery: Bool = false
}

/// Read model for a persisted `source_attribution` row.
struct SourceAttributionRecord: Identifiable, Sendable, Hashable {
    let filePath: String
    let matchKey: String?
    let navidromeSongId: String?
    let attributionKey: String?
    let sourceCollectionKey: String?
    let sourceKind: String?
    let sourceDisplayName: String?
    let downloadSource: String?
    let queryContext: String?
    let acquiredAt: String?
    let importedAt: String?

    var id: String { filePath }

    init(row: Row) {
        filePath = row["file_path"]
        matchKey = row["match_key"]
        navidromeSongId = row["navidrome_song_id"]
        attributionKey = row["attribution_key"]
        sourceCollectionKey = row["source_collection_key"]
        sourceKind = row["source_kind"]
        sourceDisplayName = row["source_display_name"]
        downloadSource = row["download_source"]
        queryContext = row["query_context"]
        acquiredAt = row["acquired_at"]
        importedAt = row["imported_at"]
    }
}

struct PlayHistoryEntry: Identifiable, Sendable {
    let id: Int64
    let songId: String
    let serverId: String
    let playedAt: Date
    let durationPlayed: Int?
    let title: String
    let artist: String
    let album: String
    let albumId: String
    let coverArt: String?
}

// MARK: - Dossier Story (Get Info ladder, step A)

/// The item's own testimony for the Dossier Sheet: everything the curation
/// database knows about how this item got here and what happened since.
/// Read-only; assembled by `DatabaseManager.dossierStory(...)`. The Get Info
/// sheet renders this prose-first, ahead of the technical metadata.
struct DossierStory: Sendable, Equatable {
    struct Admission: Sendable, Equatable {
        /// `library_membership.admitted_at` (active membership only).
        var admittedAt: Date
        /// `library_membership.admitted_by` — a `LibraryAdmissionSource` rawValue.
        var admittedBy: String
        /// `library_membership.source_detail`, e.g. "capture".
        var sourceDetail: String?
    }

    struct WaitingRoomChapter: Sendable, Equatable {
        /// `waiting_room_items.state` — a `WaitingRoomState` rawValue.
        var state: String
        var addedAt: Date
        /// `waiting_room_items.source`, e.g. "capture", "new-music".
        var source: String
        var auditionCount: Int
        var lastAuditionedAt: Date?
        var notes: String?
    }

    struct AttentionChapter: Sendable, Equatable {
        /// `attention_marks.mark_type` — an `AttentionMarkType` rawValue.
        var type: String
        var markedAt: Date
        var note: String?
    }

    struct PlayChapter: Sendable, Equatable {
        var playCount: Int
        var firstPlayedAt: Date?
        var lastPlayedAt: Date?
    }

    struct ProjectChapter: Sendable, Equatable {
        var projectId: String
        var name: String
        var addedAt: Date?
    }

    /// nil when the item has never been (actively) admitted.
    var admission: Admission?
    /// nil when the item never passed through the Waiting Room.
    var waitingRoom: WaitingRoomChapter?
    /// Active (uncleared) attention marks, newest first.
    var attentionMarks: [AttentionChapter] = []
    var likedAt: Date?
    var starredAt: Date?
    var plays: PlayChapter = PlayChapter(playCount: 0, firstPlayedAt: nil, lastPlayedAt: nil)
    /// Non-archived projects containing this item, newest addition first.
    var projects: [ProjectChapter] = []
    /// First-party provenance voices from `source_attribution` (Phase 1 plumbing).
    var attributionVoices: [SourceAttributionRecord] = []

    /// True when the database has no testimony at all for this item.
    var hasTestimony: Bool {
        admission != nil || waitingRoom != nil || !attentionMarks.isEmpty
            || likedAt != nil || starredAt != nil || plays.playCount > 0
            || !projects.isEmpty || !attributionVoices.isEmpty
    }
}

extension DatabaseManager {
    /// Assemble the dossier story for a song. `songId` drives the exact
    /// attribution join; `albumId` lets album-level voices speak for the song
    /// when no per-song v2 row resolves. `songPath` remains in the public
    /// signature for call-site compatibility but is not an identity axis.
    func dossierStory(
        songId: String,
        songPath: String?,
        albumId: String?,
        serverId: String
    ) throws -> DossierStory {
        // One read assembles every DB-derived chapter; attribution voices are
        // resolved afterwards through the shared provenance helpers.
        var story = try dbPool.read { db -> DossierStory in
            var story = try Self.dossierCommonChapters(
                db, itemId: songId, itemType: .song, serverId: serverId
            )
            story.waitingRoom = try Self.waitingRoomChapter(db, songId: songId, serverId: serverId)
            story.plays = try Self.playChapter(
                db,
                filterColumn: "song_id",
                filterValue: songId,
                serverId: serverId
            )
            return story
        }
        story.attributionVoices = try songAttributionVoices(songId: songId, albumId: albumId)
        return story
    }

    /// Assemble the dossier story for an album (admission, marks, aggregate
    /// plays across its songs, projects, attribution voices).
    func dossierStory(
        albumId: String,
        serverId: String
    ) throws -> DossierStory {
        var story = try dbPool.read { db -> DossierStory in
            var story = try Self.dossierCommonChapters(
                db, itemId: albumId, itemType: .album, serverId: serverId
            )
            // Album plays aggregate across the album's songs via the stored
            // `album_id` on each play-history row (mirrors `planeDecorations`).
            story.plays = try Self.playChapter(
                db,
                filterColumn: "album_id",
                filterValue: albumId,
                serverId: serverId
            )
            return story
        }
        story.attributionVoices = try sourceVoices(forAlbumId: albumId)
        return story
    }

    // MARK: - Dossier assembly helpers

    /// The chapters shared by songs and albums: admission, active attention
    /// marks, liked/starred timestamps, and containing projects.
    private static func dossierCommonChapters(
        _ db: Database,
        itemId: String,
        itemType: LibraryItemType,
        serverId: String
    ) throws -> DossierStory {
        var story = DossierStory()
        let type = itemType.rawValue

        // Admission — active (uncleared) membership only.
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT admitted_at, admitted_by, source_detail
                FROM library_membership
                WHERE item_id = ? AND item_type = ? AND server_id = ? AND removed_at IS NULL
                """,
            arguments: [itemId, type, serverId]
        ) {
            story.admission = DossierStory.Admission(
                admittedAt: row["admitted_at"],
                admittedBy: row["admitted_by"],
                sourceDetail: row["source_detail"]
            )
        }

        // Attention marks — active only, newest first.
        story.attentionMarks = try Row.fetchAll(
            db,
            sql: """
                SELECT mark_type, marked_at, note
                FROM attention_marks
                WHERE item_id = ? AND item_type = ? AND server_id = ? AND cleared_at IS NULL
                ORDER BY marked_at DESC
                """,
            arguments: [itemId, type, serverId]
        ).map {
            DossierStory.AttentionChapter(
                type: $0["mark_type"],
                markedAt: $0["marked_at"],
                note: $0["note"]
            )
        }

        // Liked (Resonance-local concept) and starred (navidrome-synced, active).
        story.likedAt = try Date.fetchOne(
            db,
            sql: "SELECT liked_at FROM liked_items WHERE item_id = ? AND item_type = ? AND server_id = ?",
            arguments: [itemId, type, serverId]
        )
        story.starredAt = try Date.fetchOne(
            db,
            sql: """
                SELECT starred_at FROM starred_items
                WHERE item_id = ? AND item_type = ? AND server_id = ? AND unstarred_at IS NULL
                """,
            arguments: [itemId, type, serverId]
        )

        // Non-archived projects containing this item, newest addition first.
        story.projects = try Row.fetchAll(
            db,
            sql: """
                SELECT p.id AS project_id, p.name AS name, pi.added_at AS added_at
                FROM project_items pi
                JOIN projects p ON p.id = pi.project_id
                WHERE pi.item_id = ? AND pi.item_type = ? AND pi.server_id = ?
                    AND p.archived_at IS NULL
                ORDER BY pi.added_at DESC
                """,
            arguments: [itemId, type, serverId]
        ).map {
            DossierStory.ProjectChapter(
                projectId: $0["project_id"],
                name: $0["name"],
                addedAt: $0["added_at"]
            )
        }

        return story
    }

    /// The Waiting Room chapter for a song, or nil when it never passed through.
    private static func waitingRoomChapter(
        _ db: Database,
        songId: String,
        serverId: String
    ) throws -> DossierStory.WaitingRoomChapter? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT state, source, added_at, audition_count, last_auditioned_at, notes
                FROM waiting_room_items
                WHERE song_id = ? AND server_id = ?
                """,
            arguments: [songId, serverId]
        ) else { return nil }

        return DossierStory.WaitingRoomChapter(
            state: row["state"],
            addedAt: row["added_at"],
            source: row["source"],
            auditionCount: row["audition_count"],
            lastAuditionedAt: row["last_auditioned_at"],
            notes: row["notes"]
        )
    }

    /// Aggregate play chapter over `play_history` rows matching a filter column
    /// (`song_id` for a song, `album_id` for an album's songs).
    private static func playChapter(
        _ db: Database,
        filterColumn: String,
        filterValue: String,
        serverId: String
    ) throws -> DossierStory.PlayChapter {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS play_count,
                       MIN(played_at) AS first_played,
                       MAX(played_at) AS last_played
                FROM play_history
                WHERE \(filterColumn) = ? AND server_id = ?
                """,
            arguments: [filterValue, serverId]
        ) else {
            return DossierStory.PlayChapter(playCount: 0, firstPlayedAt: nil, lastPlayedAt: nil)
        }
        return DossierStory.PlayChapter(
            playCount: row["play_count"],
            firstPlayedAt: row["first_played"],
            lastPlayedAt: row["last_played"]
        )
    }

    /// Song-level provenance uses exact Navidrome identity, then falls back to
    /// the album's exact-id voices.
    private func songAttributionVoices(
        songId: String,
        albumId: String?
    ) throws -> [SourceAttributionRecord] {
        if let attribution = try sourceAttribution(forSongId: songId) {
            return [attribution]
        }
        if let albumId,
           !albumId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try sourceVoices(forAlbumId: albumId)
        }
        return []
    }
}
