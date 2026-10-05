import XCTest
import GRDB
@testable import Resonance

/// Covers the bulk `sourceVoicesByAlbum(forAlbumIds:)` path: equivalence with the
/// single-album `sourceVoices(forAlbumId:)` API, omission of voiceless albums,
/// empty input, IN-list chunking beyond SQLite's variable limit, and dedup +
/// ordering inside the bulk resolution.
final class SourceVoicesBulkTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - Equivalence with the single-album API

    /// A multi-album fixture spanning exact matches, suffix matches, no-match
    /// songs, voiceless albums, and a source collection shared across albums.
    /// For every album id, the bulk result must equal the single-album result.
    func testBulkMatchesSingleAlbumAcrossMixedFixture() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                // album-1: two songs, one shared collection (exact) → one voice.
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/Rock/A/01.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/Rock/A/02.flac"),
                // album-2: two distinct collections, different acquired_at → two voices ordered.
                makeSong(id: "s3", albumId: "album-2", path: "/srv/music/Jazz/older.flac"),
                makeSong(id: "s4", albumId: "album-2", path: "/srv/music/Jazz/newer.flac"),
                // album-3: one suffix (music-folder-relative) match + one unmatched song.
                makeSong(id: "s5", albumId: "album-3", path: "Pop/Artist/hit.flac"),
                makeSong(id: "s6", albumId: "album-3", path: "/srv/music/Pop/orphan.flac"),
                // album-4: has a path but no attribution → voiceless, must be omitted.
                makeSong(id: "s7", albumId: "album-4", path: "/srv/music/Ambient/lonely.flac"),
                // album-5: shares collection:alpha with album-1 via a different file path.
                makeSong(id: "s8", albumId: "album-5", path: "/srv/music/Rock/B/01.flac"),
                // album-6: only blank/nil paths → voiceless.
                makeSong(id: "s9", albumId: "album-6", path: nil),
                makeSong(id: "s10", albumId: "album-6", path: "   ")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:a1", localPath: "/srv/music/Rock/A/01.flac",
                         collectionKey: "collection:alpha", songId: "s1",
                         acquiredAt: "2026-01-01T00:00:00.000Z"),
                makeAttr(key: "attr:a2", localPath: "/srv/music/Rock/A/02.flac",
                         collectionKey: "collection:alpha", songId: "s2",
                         acquiredAt: "2026-02-01T00:00:00.000Z"),
                makeAttr(key: "attr:old", localPath: "/srv/music/Jazz/older.flac",
                         collectionKey: "collection:jazz-old", songId: "s3",
                         acquiredAt: "2026-01-15T00:00:00.000Z"),
                makeAttr(key: "attr:new", localPath: "/srv/music/Jazz/newer.flac",
                         collectionKey: "collection:jazz-new", songId: "s4",
                         acquiredAt: "2026-06-15T00:00:00.000Z"),
                makeAttr(key: "attr:pop", localPath: "/srv/music/Pop/Artist/hit.flac",
                         collectionKey: "collection:pop", songId: "s5"),
                makeAttr(key: "attr:b1", localPath: "/srv/music/Rock/B/01.flac",
                         collectionKey: "collection:alpha", songId: "s8",
                         acquiredAt: "2026-03-01T00:00:00.000Z")
            ])

            let albumIds = ["album-1", "album-2", "album-3", "album-4", "album-5", "album-6"]
            let bulk = try database.sourceVoicesByAlbum(forAlbumIds: albumIds)

            for albumId in albumIds {
                let single = try database.sourceVoices(forAlbumId: albumId)
                XCTAssertEqual(bulk[albumId] ?? [], single, "mismatch for \(albumId)")
            }

            // Sanity anchors so the equivalence isn't vacuously "both empty".
            XCTAssertEqual(bulk["album-1"]?.count, 1)
            XCTAssertEqual(bulk["album-2"]?.map(\.sourceCollectionKey),
                           ["collection:jazz-new", "collection:jazz-old"])
            XCTAssertEqual(bulk["album-3"]?.map(\.attributionKey), ["attr:pop"])
            XCTAssertEqual(bulk["album-5"]?.first?.attributionKey, "attr:b1")
        }
    }

    // MARK: - Omission of voiceless albums

    func testVoicelessAlbumsAreOmittedFromResult() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/matched.flac"),
                makeSong(id: "s2", albumId: "album-2", path: "/srv/music/unmatched.flac"),
                makeSong(id: "s3", albumId: "album-3", path: nil)
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:m", localPath: "/srv/music/matched.flac",
                         collectionKey: "collection:m", songId: "s1")
            ])

            let bulk = try database.sourceVoicesByAlbum(
                forAlbumIds: ["album-1", "album-2", "album-3"]
            )

            XCTAssertEqual(Set(bulk.keys), ["album-1"])
            XCTAssertNil(bulk["album-2"])
            XCTAssertNil(bulk["album-3"])
        }
    }

    // MARK: - Empty input

    func testEmptyInputYieldsEmptyDictionary() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            XCTAssertTrue(try database.sourceVoicesByAlbum(forAlbumIds: []).isEmpty)
            // Blank / whitespace-only ids trim away to nothing too.
            XCTAssertTrue(try database.sourceVoicesByAlbum(forAlbumIds: ["", "   "]).isEmpty)
        }
    }

    // MARK: - IN-list chunking across the 999-variable boundary

    func testChunkingAcrossVariableLimit() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "real-1", path: "/srv/music/one.flac"),
                makeSong(id: "s2", albumId: "real-2", path: "/srv/music/two.flac"),
                makeSong(id: "s3", albumId: "real-3", path: "/srv/music/three.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:1", localPath: "/srv/music/one.flac",
                         collectionKey: "collection:1", songId: "s1"),
                makeAttr(key: "attr:2", localPath: "/srv/music/two.flac",
                         collectionKey: "collection:2", songId: "s2"),
                makeAttr(key: "attr:3", localPath: "/srv/music/three.flac",
                         collectionKey: "collection:3", songId: "s3")
            ])

            // Pad with absent ids so the request spans well past a single chunk
            // (1500 padding + 3 real = 1503 ids → two chunks of 999 + 504).
            var albumIds = ["real-1", "real-2", "real-3"]
            albumIds += (0..<1500).map { "absent-\($0)" }

            let bulk = try database.sourceVoicesByAlbum(forAlbumIds: albumIds)

            XCTAssertEqual(Set(bulk.keys), ["real-1", "real-2", "real-3"])
            for albumId in ["real-1", "real-2", "real-3"] {
                XCTAssertEqual(bulk[albumId] ?? [], try database.sourceVoices(forAlbumId: albumId))
            }
        }
    }

    // MARK: - Dedup + ordering inside the bulk path

    func testDedupAndOrderingWithinBulkResolution() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/one.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/two.flac"),
                makeSong(id: "s3", albumId: "album-1", path: "/srv/music/three.flac"),
                makeSong(id: "s4", albumId: "album-1", path: "/srv/music/four.flac")
            ], serverId: serverId)

            // one/three share a collection (keep the newer); two is a distinct
            // newer source; four has a NULL acquired_at and must sort last.
            try database.upsertSourceAttributions([
                makeAttr(key: "attr:shared-old", localPath: "/srv/music/one.flac",
                         collectionKey: "collection:shared", songId: "s1",
                         acquiredAt: "2026-01-01T00:00:00.000Z"),
                makeAttr(key: "attr:shared-new", localPath: "/srv/music/three.flac",
                         collectionKey: "collection:shared", songId: "s3",
                         acquiredAt: "2026-05-01T00:00:00.000Z"),
                makeAttr(key: "attr:other", localPath: "/srv/music/two.flac",
                         collectionKey: "collection:other", songId: "s2",
                         acquiredAt: "2026-06-01T00:00:00.000Z"),
                makeAttr(key: "attr:undated", localPath: "/srv/music/four.flac",
                         collectionKey: "collection:undated", songId: "s4", acquiredAt: nil)
            ])

            let voices = try XCTUnwrap(
                database.sourceVoicesByAlbum(forAlbumIds: ["album-1"])["album-1"]
            )

            XCTAssertEqual(voices.map(\.sourceCollectionKey),
                           ["collection:other", "collection:shared", "collection:undated"])
            // The kept representative of the shared collection is the newer acquisition.
            XCTAssertEqual(voices.first(where: { $0.sourceCollectionKey == "collection:shared" })?.attributionKey,
                           "attr:shared-new")
        }
    }

    // MARK: - Helpers

    private func makeSong(id: String, albumId: String, path: String?) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            album: "Album",
            albumId: albumId,
            artist: "Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Rock",
            duration: 200,
            bitRate: 320,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            path: path
        )
    }

    private func makeAttr(
        key: String,
        localPath: String,
        collectionKey: String,
        songId: String,
        acquiredAt: String? = "2026-02-01T00:00:00.000Z"
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: localPath,
            sourceCollectionKey: collectionKey,
            sourceKind: "apple_playlist",
            sourceDisplayName: "Display \(key)",
            downloadSource: "fetcher",
            queryContext: "ctx",
            acquiredAt: acquiredAt,
            contractVersion: 2,
            navidromeSongId: songId
        )
    }

    /// Isolates DatabaseManager's on-disk store to a throwaway home directory,
    /// mirroring SourceVoicesTests.
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
