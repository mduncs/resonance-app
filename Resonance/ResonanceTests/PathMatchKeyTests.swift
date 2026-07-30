import XCTest
import GRDB
@testable import Resonance

final class PathMatchKeyTests: XCTestCase {
    func testAbsoluteAndRelativePathsShareCanonicalTrailingKey() {
        XCTAssertEqual(
            PathMatchKey.canonical("/Volumes/Library/Album/Artist/Track.m4a"),
            PathMatchKey.canonical("Album/Artist/Track.m4a")
        )
        XCTAssertEqual(
            PathMatchKey.canonical("/Volumes/Library/Album/Artist/Track.m4a"),
            "album/artist/track.m4a"
        )
    }

    func testForwardSeparatorsRepeatsAndTrailingSeparatorsNormalize() {
        XCTAssertEqual(
            PathMatchKey.canonical("/Music/Album/Artist//Track.FLAC////"),
            "album/artist/track.flac"
        )
    }

    func testBackslashRemainsInsidePosixPathComponent() {
        XCTAssertEqual(
            PathMatchKey.canonical(#"/Music/Album/Fuck You! Overkill (Men At Work \ Lily Allen).mp3"#),
            #"music/album/fuck you! overkill (men at work \ lily allen).mp3"#
        )
    }

    func testCaseFoldingIsLocaleStable() {
        XCTAssertEqual(
            PathMatchKey.canonical("ALBUM/ARTIST/SONG.M4A"),
            PathMatchKey.canonical("album/artist/song.m4a")
        )
    }

    func testNFCAndNFDAccentsCanonicalizeEqually() {
        let nfc = "Beyoncé/Album/Café.m4a"
        let nfd = nfc.decomposedStringWithCanonicalMapping

        XCTAssertEqual(PathMatchKey.canonical(nfc), PathMatchKey.canonical(nfd))
        XCTAssertEqual(
            PathMatchKey.canonical(nfd),
            PathMatchKey.canonical(nfd)?.precomposedStringWithCanonicalMapping
        )
    }

    func testEmptyAndDegenerateInputsReturnNil() {
        XCTAssertNil(PathMatchKey.canonical(""))
        XCTAssertNil(PathMatchKey.canonical("  \n "))
        XCTAssertNil(PathMatchKey.canonical("////"))
        XCTAssertNil(PathMatchKey.canonical("././"))
        XCTAssertNil(PathMatchKey.canonical("valid/file.m4a", components: 0))
    }

    func testMigrationBackfillsPreexistingRowsAndCreatesIndexes() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "cached_songs") { table in
                table.primaryKey("id", .text)
                table.column("path", .text)
            }
            try db.create(table: "source_attribution") { table in
                table.primaryKey("file_path", .text)
            }
            try db.execute(
                sql: "INSERT INTO cached_songs (id, path) VALUES (?, ?), (?, NULL)",
                arguments: ["song-1", "Album/Artist/Track.m4a", "song-2"]
            )
            for index in 0..<251 {
                try db.execute(
                    sql: "INSERT INTO cached_songs (id, path) VALUES (?, ?)",
                    arguments: [
                        String(format: "batch-%03d", index),
                        "Batch/Artist/Track-\(index).m4a"
                    ]
                )
            }
            try db.execute(
                sql: "INSERT INTO source_attribution (file_path) VALUES (?)",
                arguments: ["/Volumes/OldRoot/Album/Artist/Track.m4a"]
            )

            try DatabaseManager.migratePathMatchKeys(db)

            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT match_key FROM cached_songs WHERE id = 'song-1'"
                ),
                "album/artist/track.m4a"
            )
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT match_key FROM cached_songs WHERE id = 'song-2'"
                )
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cached_songs WHERE match_key IS NOT NULL"
                ),
                252,
                "backfill must continue past its 250-row batch boundary"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT match_key FROM source_attribution"
                ),
                "album/artist/track.m4a"
            )

            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND name IN ('idx_cached_songs_match_key', 'idx_source_attribution_match_key')
                    ORDER BY name
                    """
            )
            XCTAssertEqual(
                indexes,
                ["idx_cached_songs_match_key", "idx_source_attribution_match_key"]
            )
        }
    }

    func testIndexedHitWinsWithoutConsultingNullKeyFallback() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeAttribution(
                    key: "indexed",
                    path: "/zzz/Album/Artist/Track.m4a"
                )
            ])
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO source_attribution (file_path, match_key, attribution_key)
                        VALUES (?, NULL, ?)
                        """,
                    arguments: ["/aaa/Album/Artist/Track.m4a", "legacy-null"]
                )
            }

            let match = try database.sourceAttribution(
                matchingSuffixOf: "Album/Artist/Track.m4a"
            )
            XCTAssertEqual(match?.attributionKey, "indexed")

            let queryPlan = try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        EXPLAIN QUERY PLAN
                        SELECT * FROM source_attribution WHERE match_key = ?
                        """,
                    arguments: ["album/artist/track.m4a"]
                ).map { $0["detail"] as String }
            }
            XCTAssertTrue(
                queryPlan.contains { $0.contains("idx_source_attribution_match_key") },
                "expected indexed match_key lookup, got \(queryPlan)"
            )
        }
    }

    func testEveryCachedSongWritePathPopulatesMatchKey() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.saveSongs(
                [makeSong(id: "save", path: "A/B/Save.m4a")],
                serverId: "server"
            )
            try database.admitSongAndRelated(
                makeSong(id: "admit", path: "A/B/Admit.m4a"),
                serverId: "server"
            )
            try database.upsertWaitingRoomItem(
                song: makeSong(id: "waiting", path: "A/B/Waiting.m4a"),
                serverId: "server"
            )

            let keys = try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, match_key FROM cached_songs ORDER BY id"
                ).reduce(into: [String: String]()) { result, row in
                    result[row["id"]] = row["match_key"]
                }
            }
            XCTAssertEqual(keys["save"], "a/b/save.m4a")
            XCTAssertEqual(keys["admit"], "a/b/admit.m4a")
            XCTAssertEqual(keys["waiting"], "a/b/waiting.m4a")
        }
    }

    func testCanonicalKeyCollisionUsesLongestSuffixAndDeterministicPathTieBreak() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeAttribution(
                    key: "winner",
                    path: "/aaa/OldRoot/Album/Artist/Track.m4a"
                ),
                makeAttribution(
                    key: "later",
                    path: "/zzz/NewRoot/Album/Artist/Track.m4a"
                )
            ])

            let match = try database.sourceAttribution(
                matchingSuffixOf: "Album/Artist/Track.m4a"
            )
            XCTAssertEqual(match?.attributionKey, "winner")
            XCTAssertEqual(match?.filePath, "/aaa/OldRoot/Album/Artist/Track.m4a")
        }
    }

    private func makeAttribution(
        key: String,
        path: String
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: path,
            sourceCollectionKey: "collection:test",
            sourceKind: "apple_playlist",
            sourceDisplayName: key,
            downloadSource: "gamdl",
            queryContext: nil,
            acquiredAt: nil,
            contractVersion: 1
        )
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            album: "Album",
            albumId: "album",
            artist: "Artist",
            artistId: "artist",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: nil,
            duration: 180,
            bitRate: 256,
            contentType: "audio/mp4",
            suffix: "m4a",
            coverArt: nil,
            path: path
        )
    }

    private func withTemporaryUserHome<T>(_ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let previousHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", homeURL.path, 1)
        defer {
            if let previousHome {
                setenv("CFFIXED_USER_HOME", previousHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            try? fileManager.removeItem(at: homeURL)
        }

        return try body()
    }
}
