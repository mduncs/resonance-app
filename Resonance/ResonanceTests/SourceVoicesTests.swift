import XCTest
import GRDB
@testable import Resonance

/// Covers the album-level `sourceVoices(forAlbumId:)` join and the v6
/// persistence of `Song.path` through the songs cache.
final class SourceVoicesTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - One album, one source

    func testMultipleSongsMappingToOneSourceYieldOneVoice() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/Rock/Artist/01 Track.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/Rock/Artist/02 Track.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:one", localPath: "/srv/music/Rock/Artist/01 Track.flac",
                         collectionKey: "collection:alpha", songId: "s1"),
                makeAttr(key: "attr:two", localPath: "/srv/music/Rock/Artist/02 Track.flac",
                         collectionKey: "collection:alpha", songId: "s2")
            ])

            let voices = try database.sourceVoices(forAlbumId: "album-1")

            // Both songs resolve to the same source_collection_key → collapsed to one voice.
            XCTAssertEqual(voices.count, 1)
            XCTAssertEqual(voices.first?.sourceCollectionKey, "collection:alpha")
        }
    }

    // MARK: - One album, two sources, ordering

    func testAlbumSpanningTwoSourcesYieldsTwoVoicesOrderedByAcquiredAtDescending() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/Rock/A/older.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/Rock/B/newer.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:old", localPath: "/srv/music/Rock/A/older.flac",
                         collectionKey: "collection:alpha", songId: "s1",
                         acquiredAt: "2026-01-01T00:00:00.000Z"),
                makeAttr(key: "attr:new", localPath: "/srv/music/Rock/B/newer.flac",
                         collectionKey: "collection:beta", songId: "s2",
                         acquiredAt: "2026-06-01T00:00:00.000Z")
            ])

            let voices = try database.sourceVoices(forAlbumId: "album-1")

            XCTAssertEqual(voices.map(\.sourceCollectionKey), ["collection:beta", "collection:alpha"])
        }
    }

    func testVoicesWithNilAcquiredAtSortLast() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/dated.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/undated.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:dated", localPath: "/srv/music/dated.flac",
                         collectionKey: "collection:dated", songId: "s1",
                         acquiredAt: "2026-03-01T00:00:00.000Z"),
                makeAttr(key: "attr:undated", localPath: "/srv/music/undated.flac",
                         collectionKey: "collection:undated", songId: "s2", acquiredAt: nil)
            ])

            let voices = try database.sourceVoices(forAlbumId: "album-1")

            // Dated voice first, NULL acquired_at last.
            XCTAssertEqual(voices.map(\.sourceCollectionKey), ["collection:dated", "collection:undated"])
        }
    }

    // MARK: - Exact song-id resolution

    func testResolvesBySongIdWhenFetcherAndNavidromePathsDiffer() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "Artist/Album/01-01 - Synthetic.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:one", localPath: "/Ingest/Fetcher/Completely Different.flac",
                         collectionKey: "collection:alpha", songId: "s1")
            ])

            let voices = try database.sourceVoices(forAlbumId: "album-1")

            XCTAssertEqual(voices.count, 1)
            XCTAssertEqual(voices.first?.attributionKey, "attr:one")
        }
    }

    // MARK: - Empty results

    func testResolvesWhenSongHasNoPath() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: nil)
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:one", localPath: "/srv/music/Rock/Artist/01 Track.flac",
                         collectionKey: "collection:alpha", songId: "s1")
            ])

            XCTAssertEqual(
                try database.sourceVoices(forAlbumId: "album-1").first?.attributionKey,
                "attr:one"
            )
        }
    }

    func testEmptyWhenNoAttributionMatches() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/Pop/unrelated.flac")
            ], serverId: serverId)

            try database.upsertSourceAttributions([
                makeAttr(key: "attr:one", localPath: "/srv/music/Rock/Artist/01 Track.flac",
                         collectionKey: "collection:alpha")
            ])

            XCTAssertTrue(try database.sourceVoices(forAlbumId: "album-1").isEmpty)
        }
    }

    func testEmptyForBlankAlbumId() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            XCTAssertTrue(try database.sourceVoices(forAlbumId: "   ").isEmpty)
        }
    }

    // MARK: - Dedup by collection key across distinct file paths

    func testDeduplicatesByCollectionKeyKeepingMostRecentlyAcquired() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "/srv/music/one.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/srv/music/two.flac"),
                makeSong(id: "s3", albumId: "album-1", path: "/srv/music/three.flac")
            ], serverId: serverId)

            // one.flac and three.flac share a collection key with different acquired_at;
            // two.flac is a second distinct source.
            try database.upsertSourceAttributions([
                makeAttr(key: "attr:a-old", localPath: "/srv/music/one.flac",
                         collectionKey: "collection:shared", songId: "s1",
                         acquiredAt: "2026-01-01T00:00:00.000Z"),
                makeAttr(key: "attr:a-new", localPath: "/srv/music/three.flac",
                         collectionKey: "collection:shared", songId: "s3",
                         acquiredAt: "2026-05-01T00:00:00.000Z"),
                makeAttr(key: "attr:b", localPath: "/srv/music/two.flac",
                         collectionKey: "collection:other", songId: "s2",
                         acquiredAt: "2026-03-01T00:00:00.000Z")
            ])

            let voices = try database.sourceVoices(forAlbumId: "album-1")

            XCTAssertEqual(voices.count, 2)
            XCTAssertEqual(voices.map(\.sourceCollectionKey), ["collection:shared", "collection:other"])
            // The kept representative of the shared collection is the newer acquisition.
            XCTAssertEqual(voices.first?.attributionKey, "attr:a-new")
        }
    }

    // MARK: - v6 persistence round-trip

    func testSongPathPersistsThroughCacheRoundTrip() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "Rock/Artist/01 Track.flac")
            ], serverId: serverId)

            let reloaded = try XCTUnwrap(database.loadCachedSong(id: "s1", serverId: serverId))
            XCTAssertEqual(reloaded.path, "Rock/Artist/01 Track.flac")
        }
    }

    func testUpsertPreservesExistingPathWhenReplacementHasNone() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: "Rock/Artist/01 Track.flac")
            ], serverId: serverId)
            // A later cache write for the same id carrying no path must not clobber it.
            try database.saveSongs([
                makeSong(id: "s1", albumId: "album-1", path: nil)
            ], serverId: serverId)

            let reloaded = try XCTUnwrap(database.loadCachedSong(id: "s1", serverId: serverId))
            XCTAssertEqual(reloaded.path, "Rock/Artist/01 Track.flac")
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
        songId: String? = nil,
        acquiredAt: String? = "2026-02-01T00:00:00.000Z"
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: localPath,
            sourceCollectionKey: collectionKey,
            sourceKind: "apple_playlist",
            sourceDisplayName: "Display \(key)",
            downloadSource: "gamdl",
            queryContext: "ctx",
            acquiredAt: acquiredAt,
            contractVersion: songId == nil ? 1 : 2,
            navidromeSongId: songId
        )
    }

    /// Isolates DatabaseManager's on-disk store to a throwaway home directory,
    /// mirroring SourceAttributionTests / CurationModelDraftTests.
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
