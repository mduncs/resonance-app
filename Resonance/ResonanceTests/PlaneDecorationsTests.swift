import XCTest
import GRDB
@testable import Resonance

/// Covers the bulk `planeDecorations(forAlbumIds:)` path (OP-2): attention-mark
/// aggregation with loved outranking interesting, play-count summation across an
/// album's songs, waiting-room on-audition membership (unheard/interesting true,
/// admitted/rejected false), omission of state-less albums, empty input, IN-list
/// chunking beyond SQLite's variable limit, and a combined all-fields fixture.
final class PlaneDecorationsTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - Attention marks: loved outranks interesting

    func testLovedOutranksInterestingAggregation() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let songs = [
                // album-1: one loved + one interesting song → loved wins.
                makeSong(id: "s1", albumId: "album-1", path: "/m/1.flac"),
                makeSong(id: "s2", albumId: "album-1", path: "/m/2.flac"),
                // album-2: only interesting → interesting.
                makeSong(id: "s3", albumId: "album-2", path: "/m/3.flac"),
                // album-3: song interesting but album-level loved mark → loved wins.
                makeSong(id: "s4", albumId: "album-3", path: "/m/4.flac")
            ]
            try database.saveSongs(songs, serverId: serverId)

            try database.markAttention(id: "s1", type: .song, serverId: serverId, markType: .loved)
            try database.markAttention(id: "s2", type: .song, serverId: serverId, markType: .interesting)
            try database.markAttention(id: "s3", type: .song, serverId: serverId, markType: .interesting)
            try database.markAttention(id: "s4", type: .song, serverId: serverId, markType: .interesting)
            try database.markAttention(id: "album-3", type: .album, serverId: serverId, markType: .loved)

            let decorations = try database.planeDecorations(
                forAlbumIds: ["album-1", "album-2", "album-3"]
            )

            XCTAssertEqual(decorations["album-1"]?.mark, "loved")
            XCTAssertEqual(decorations["album-2"]?.mark, "interesting")
            XCTAssertEqual(decorations["album-3"]?.mark, "loved")
        }
    }

    // MARK: - Play counts sum across an album's songs

    func testPlayCountSumsAcrossSongs() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let s1 = makeSong(id: "s1", albumId: "album-1", path: "/m/1.flac")
            let s2 = makeSong(id: "s2", albumId: "album-1", path: "/m/2.flac")
            // A song on a different album whose plays must not leak in.
            let s3 = makeSong(id: "s3", albumId: "album-2", path: "/m/3.flac")
            try database.saveSongs([s1, s2, s3], serverId: serverId)

            // 2 plays of s1 + 3 plays of s2 → album-1 playCount == 5.
            for _ in 0..<2 { try database.recordPlay(song: s1, serverId: serverId) }
            for _ in 0..<3 { try database.recordPlay(song: s2, serverId: serverId) }
            try database.recordPlay(song: s3, serverId: serverId)

            let decorations = try database.planeDecorations(forAlbumIds: ["album-1", "album-2"])

            XCTAssertEqual(decorations["album-1"]?.playCount, 5)
            XCTAssertEqual(decorations["album-1"]?.mark, nil)
            XCTAssertEqual(decorations["album-1"]?.onAudition, false)
            XCTAssertEqual(decorations["album-2"]?.playCount, 1)
        }
    }

    // MARK: - On-audition membership

    func testOnAuditionTrueForUnheardAndInterestingFalseForSettled() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let unheardSong = makeSong(id: "s1", albumId: "album-unheard", path: "/m/1.flac")
            let interestingSong = makeSong(id: "s2", albumId: "album-interesting", path: "/m/2.flac")
            let admittedSong = makeSong(id: "s3", albumId: "album-admitted", path: "/m/3.flac")
            let rejectedSong = makeSong(id: "s4", albumId: "album-rejected", path: "/m/4.flac")
            try database.saveSongs(
                [unheardSong, interestingSong, admittedSong, rejectedSong],
                serverId: serverId
            )

            try database.upsertWaitingRoomItem(song: unheardSong, serverId: serverId, state: .unheard)
            try database.upsertWaitingRoomItem(song: interestingSong, serverId: serverId, state: .interesting)
            try database.upsertWaitingRoomItem(song: admittedSong, serverId: serverId, state: .admitted)
            try database.upsertWaitingRoomItem(song: rejectedSong, serverId: serverId, state: .rejected)

            let decorations = try database.planeDecorations(forAlbumIds: [
                "album-unheard", "album-interesting", "album-admitted", "album-rejected"
            ])

            XCTAssertEqual(decorations["album-unheard"]?.onAudition, true)
            XCTAssertEqual(decorations["album-interesting"]?.onAudition, true)
            // Settled albums carry no other signal, so they are omitted entirely.
            XCTAssertNil(decorations["album-admitted"])
            XCTAssertNil(decorations["album-rejected"])
        }
    }

    // MARK: - Omission of state-less albums (and cleared marks)

    func testStatelessAndClearedAlbumsAreOmitted() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.saveSongs([
                // album-1: songs but no marks/plays/audition → omitted.
                makeSong(id: "s1", albumId: "album-1", path: "/m/1.flac"),
                // album-2: a loved mark that gets cleared → no active signal → omitted.
                makeSong(id: "s2", albumId: "album-2", path: "/m/2.flac")
            ], serverId: serverId)

            try database.markAttention(id: "s2", type: .song, serverId: serverId, markType: .loved)
            try database.clearAttention(id: "s2", type: .song, serverId: serverId, markType: .loved)

            let decorations = try database.planeDecorations(forAlbumIds: ["album-1", "album-2"])

            XCTAssertTrue(decorations.isEmpty)
        }
    }

    // MARK: - Empty input

    func testEmptyInputYieldsEmptyDictionary() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            XCTAssertTrue(try database.planeDecorations(forAlbumIds: []).isEmpty)
            XCTAssertTrue(try database.planeDecorations(forAlbumIds: ["", "   "]).isEmpty)
        }
    }

    // MARK: - IN-list chunking across the 999-variable boundary

    func testChunkingAcrossVariableLimit() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let s1 = makeSong(id: "s1", albumId: "real-1", path: "/m/1.flac")
            let s2 = makeSong(id: "s2", albumId: "real-2", path: "/m/2.flac")
            let s3 = makeSong(id: "s3", albumId: "real-3", path: "/m/3.flac")
            try database.saveSongs([s1, s2, s3], serverId: serverId)

            try database.markAttention(id: "s1", type: .song, serverId: serverId, markType: .loved)
            try database.recordPlay(song: s2, serverId: serverId)
            try database.upsertWaitingRoomItem(song: s3, serverId: serverId, state: .unheard)

            // Pad with absent ids so the request spans well past a single chunk
            // (1500 padding + 3 real = 1503 ids → two chunks of 999 + 504).
            var albumIds = ["real-1", "real-2", "real-3"]
            albumIds += (0..<1500).map { "absent-\($0)" }

            let decorations = try database.planeDecorations(forAlbumIds: albumIds)

            XCTAssertEqual(Set(decorations.keys), ["real-1", "real-2", "real-3"])
            XCTAssertEqual(decorations["real-1"]?.mark, "loved")
            XCTAssertEqual(decorations["real-2"]?.playCount, 1)
            XCTAssertEqual(decorations["real-3"]?.onAudition, true)
        }
    }

    // MARK: - Combined fixture: all three fields on one album

    func testCombinedFixtureAssertsAllThreeFields() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let played = makeSong(id: "s1", albumId: "album-1", path: "/m/1.flac")
            let loved = makeSong(id: "s2", albumId: "album-1", path: "/m/2.flac")
            let auditioning = makeSong(id: "s3", albumId: "album-1", path: "/m/3.flac")
            try database.saveSongs([played, loved, auditioning], serverId: serverId)

            try database.markAttention(id: "s2", type: .song, serverId: serverId, markType: .loved)
            for _ in 0..<4 { try database.recordPlay(song: played, serverId: serverId) }
            try database.upsertWaitingRoomItem(song: auditioning, serverId: serverId, state: .interesting)

            let decoration = try XCTUnwrap(
                database.planeDecorations(forAlbumIds: ["album-1"])["album-1"]
            )

            XCTAssertEqual(decoration.mark, "loved")
            XCTAssertEqual(decoration.playCount, 4)
            XCTAssertEqual(decoration.onAudition, true)
        }
    }

    // MARK: - Growing Edge freshness (NM-2)

    /// `markDiscoverySeen` flips exactly one album's row, is idempotent, and no-ops
    /// on an unknown album — asserted through the unseen count so no cached_albums
    /// join is needed.
    func testMarkDiscoverySeenRowLevelBehavior() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.recordDiscoveredAlbums(["a1", "a2"], serverId: serverId)
            XCTAssertEqual(try database.unseenDiscoveryCount(serverId: serverId), 2)

            try database.markDiscoverySeen(albumId: "a1", serverId: serverId)
            XCTAssertEqual(try database.unseenDiscoveryCount(serverId: serverId), 1)

            // Idempotent, and marking an untracked album changes nothing.
            try database.markDiscoverySeen(albumId: "a1", serverId: serverId)
            try database.markDiscoverySeen(albumId: "absent", serverId: serverId)
            XCTAssertEqual(try database.unseenDiscoveryCount(serverId: serverId), 1)
        }
    }

    /// The bulk decoration read carries freshness: an unseen discovery surfaces
    /// even with no other signal, and once seen (with nothing else) it drops out,
    /// keeping the dict lean.
    func testPlaneDecorationsCarriesDiscoveryFreshness() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            try database.recordDiscoveredAlbums(["album-1"], serverId: serverId)

            let unseen = try XCTUnwrap(
                database.planeDecorations(forAlbumIds: ["album-1"])["album-1"]
            )
            XCTAssertNotNil(unseen.discoveredAt)
            XCTAssertFalse(unseen.isSeenDiscovery)
            XCTAssertNil(unseen.mark)
            XCTAssertEqual(unseen.playCount, 0)

            try database.markDiscoverySeen(albumId: "album-1", serverId: serverId)

            // Seen and otherwise blank → omitted (renders nothing on the plane).
            XCTAssertNil(try database.planeDecorations(forAlbumIds: ["album-1"])["album-1"])
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

    /// Isolates DatabaseManager's on-disk store to a throwaway home directory,
    /// mirroring SourceVoicesBulkTests.
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
