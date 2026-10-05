import XCTest
import GRDB
@testable import Resonance

/// Covers the read-only `dossierStory(...)` assembly on `DatabaseManager`
/// (Get Info ladder, step A): every chapter sourced from a different table,
/// plus album-level aggregation and the song attribution resolution ladder.
final class DossierStoryTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - 1. Empty story

    func testEmptyStoryForUnknownSong() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let story = try database.dossierStory(
                songId: "never-seen",
                songPath: nil,
                albumId: nil,
                serverId: serverId
            )

            XCTAssertFalse(story.hasTestimony)
            XCTAssertNil(story.admission)
            XCTAssertNil(story.waitingRoom)
            XCTAssertTrue(story.attentionMarks.isEmpty)
            XCTAssertNil(story.likedAt)
            XCTAssertNil(story.starredAt)
            XCTAssertEqual(story.plays.playCount, 0)
            XCTAssertNil(story.plays.firstPlayedAt)
            XCTAssertNil(story.plays.lastPlayedAt)
            XCTAssertTrue(story.projects.isEmpty)
            XCTAssertTrue(story.attributionVoices.isEmpty)
        }
    }

    // MARK: - Server-id discipline (folded into the empty-story point)

    func testStoryIsScopedByServerId() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            // Seed every chapter under one server id...
            try database.saveSongs([makeSong(id: "s1", albumId: "album-1", path: "/srv/music/a.flac")], serverId: serverId)
            try database.recordPlay(song: makeSong(id: "s1", albumId: "album-1", path: nil), serverId: serverId)
            try database.starItem(id: "s1", type: "song", serverId: serverId)

            // ...and read under a different one: it must see nothing.
            let story = try database.dossierStory(
                songId: "s1",
                songPath: "/srv/music/a.flac",
                albumId: "album-1",
                serverId: "srv-other"
            )

            XCTAssertFalse(story.hasTestimony)
            XCTAssertNil(story.starredAt)
            XCTAssertEqual(story.plays.playCount, 0)
        }
    }

    // MARK: - 2. Full song story

    func testFullSongStoryPopulatesEveryChapter() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let song = makeSong(id: "s1", albumId: "album-1", path: "/srv/music/Artist/01 Track.flac")

            // Waiting Room row (also caches the song without admitting it).
            try database.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .unheard,
                source: "capture",
                notes: "worth a relisten"
            )
            // Explicit admission with a source detail.
            try database.admitToLibrary(
                id: song.id,
                type: .song,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "capture"
            )
            // One active attention mark with a note.
            try database.markAttention(
                id: song.id,
                type: .song,
                serverId: serverId,
                markType: .interesting,
                note: "grow on me"
            )
            try database.likeItem(id: song.id, type: "song", serverId: serverId)
            try database.starItem(id: song.id, type: "song", serverId: serverId)

            // Two plays, spaced so first/last ordering is deterministic.
            try database.recordPlay(song: song, serverId: serverId)
            Thread.sleep(forTimeInterval: 0.05)
            try database.recordPlay(song: song, serverId: serverId)

            // A project containing the song.
            let project = Project(serverId: serverId, name: "Mixtape")
            try database.saveProject(project)
            try database.addProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: serverId,
                position: 0
            )

            let story = try database.dossierStory(
                songId: song.id,
                songPath: song.path,
                albumId: song.albumId,
                serverId: serverId
            )

            XCTAssertTrue(story.hasTestimony)

            // Admission
            let admission = try XCTUnwrap(story.admission)
            XCTAssertEqual(admission.admittedBy, LibraryAdmissionSource.manual.rawValue)
            XCTAssertEqual(admission.sourceDetail, "capture")

            // Waiting Room
            let waitingRoom = try XCTUnwrap(story.waitingRoom)
            XCTAssertEqual(waitingRoom.state, WaitingRoomState.unheard.rawValue)
            XCTAssertEqual(waitingRoom.source, "capture")
            XCTAssertEqual(waitingRoom.notes, "worth a relisten")
            XCTAssertEqual(waitingRoom.auditionCount, 0)

            // Attention
            XCTAssertEqual(story.attentionMarks.count, 1)
            let mark = try XCTUnwrap(story.attentionMarks.first)
            XCTAssertEqual(mark.type, AttentionMarkType.interesting.rawValue)
            XCTAssertEqual(mark.note, "grow on me")

            // Liked / starred
            XCTAssertNotNil(story.likedAt)
            XCTAssertNotNil(story.starredAt)

            // Plays
            XCTAssertEqual(story.plays.playCount, 2)
            let first = try XCTUnwrap(story.plays.firstPlayedAt)
            let last = try XCTUnwrap(story.plays.lastPlayedAt)
            XCTAssertLessThan(first, last)

            // Projects
            XCTAssertEqual(story.projects.count, 1)
            XCTAssertEqual(story.projects.first?.name, "Mixtape")
            XCTAssertEqual(story.projects.first?.projectId, project.id)
        }
    }

    // MARK: - 3. Album story aggregates plays across songs + attribution

    func testAlbumStoryAggregatesPlaysAndAttribution() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            let songA = makeSong(id: "sa", albumId: "album-1", path: "/srv/music/Artist/01.flac")
            let songB = makeSong(id: "sb", albumId: "album-1", path: "/srv/music/Artist/02.flac")
            try database.saveSongs([songA, songB], serverId: serverId)

            // Three plays spread across the two songs (album_id is denormalized on each row).
            try database.recordPlay(song: songA, serverId: serverId)
            try database.recordPlay(song: songB, serverId: serverId)
            try database.recordPlay(song: songA, serverId: serverId)

            // Album-level attribution via exact Navidrome song ids.
            try database.upsertSourceAttributions([
                makeAttr(key: "attr:a", localPath: "/fetcher/a.flac",
                         collectionKey: "collection:alpha", songId: songA.id),
                makeAttr(key: "attr:b", localPath: "/fetcher/b.flac",
                         collectionKey: "collection:alpha", songId: songB.id)
            ])

            let story = try database.dossierStory(albumId: "album-1", serverId: serverId)

            XCTAssertEqual(story.plays.playCount, 3)
            XCTAssertNotNil(story.plays.firstPlayedAt)
            XCTAssertNotNil(story.plays.lastPlayedAt)
            XCTAssertFalse(story.attributionVoices.isEmpty)
        }
    }

    // MARK: - 4. Song attribution resolution ladder

    func testSongAttributionExactThenAlbumFallback() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            // Exact song-id match → one voice, even with unrelated paths.
            let exactSong = makeSong(id: "se", albumId: "album-x", path: "/srv/music/exact.flac")
            try database.saveSongs([exactSong], serverId: serverId)
            try database.upsertSourceAttributions([
                makeAttr(key: "attr:exact", localPath: "/fetcher/unrelated.flac",
                         collectionKey: "collection:exact", songId: exactSong.id)
            ])

            let exactStory = try database.dossierStory(
                songId: exactSong.id,
                songPath: "/srv/music/exact.flac",
                albumId: exactSong.albumId,
                serverId: serverId
            )
            XCTAssertEqual(exactStory.attributionVoices.count, 1)
            XCTAssertEqual(exactStory.attributionVoices.first?.sourceCollectionKey, "collection:exact")

            // No per-file match, but album has voices via a sibling song → album fallback.
            let sibling = makeSong(id: "ss", albumId: "album-fb", path: "/srv/music/matched.flac")
            let orphan = makeSong(id: "so", albumId: "album-fb", path: "/srv/music/unmatched.flac")
            try database.saveSongs([sibling, orphan], serverId: serverId)
            try database.upsertSourceAttributions([
                makeAttr(key: "attr:sib", localPath: "/fetcher/sibling.flac",
                         collectionKey: "collection:fallback", songId: sibling.id)
            ])

            let fallbackStory = try database.dossierStory(
                songId: orphan.id,
                songPath: "/srv/music/unmatched.flac",
                albumId: "album-fb",
                serverId: serverId
            )
            XCTAssertFalse(fallbackStory.attributionVoices.isEmpty)
            XCTAssertEqual(fallbackStory.attributionVoices.first?.sourceCollectionKey, "collection:fallback")

            // Nil path + nil albumId → empty.
            let bareStory = try database.dossierStory(
                songId: "so",
                songPath: nil,
                albumId: nil,
                serverId: serverId
            )
            XCTAssertTrue(bareStory.attributionVoices.isEmpty)
        }
    }

    // MARK: - 5. Exclusions (soft-deleted state must not appear)

    func testExclusionsHideUnstarredClearedAndArchived() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let song = makeSong(id: "s1", albumId: "album-1", path: nil)
            try database.saveSongs([song], serverId: serverId)

            // Star then unstar → starredAt nil.
            try database.starItem(id: song.id, type: "song", serverId: serverId)
            try database.unstarItem(id: song.id, type: "song", serverId: serverId)

            // Mark then clear attention → absent from attentionMarks.
            try database.markAttention(id: song.id, type: .song, serverId: serverId, markType: .later)
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .later)

            // Project containing the song, then archived → absent from projects.
            let project = Project(serverId: serverId, name: "Shelved")
            try database.saveProject(project)
            try database.addProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: serverId,
                position: 0
            )
            try database.archiveProject(id: project.id, serverId: serverId)

            let story = try database.dossierStory(
                songId: song.id,
                songPath: nil,
                albumId: nil,
                serverId: serverId
            )

            XCTAssertNil(story.starredAt)
            XCTAssertTrue(story.attentionMarks.isEmpty)
            XCTAssertTrue(story.projects.isEmpty)
        }
    }

    // MARK: - 6. hasTestimony when only plays exist

    func testHasTestimonyTrueWithOnlyPlays() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()

            // No saveSongs, no admission, no marks — only a play row.
            let song = makeSong(id: "s1", albumId: "album-1", path: nil)
            try database.recordPlay(song: song, serverId: serverId)

            let story = try database.dossierStory(
                songId: song.id,
                songPath: nil,
                albumId: nil,
                serverId: serverId
            )

            XCTAssertTrue(story.hasTestimony)
            XCTAssertNil(story.admission)
            XCTAssertNil(story.waitingRoom)
            XCTAssertTrue(story.attentionMarks.isEmpty)
            XCTAssertNil(story.likedAt)
            XCTAssertNil(story.starredAt)
            XCTAssertTrue(story.projects.isEmpty)
            XCTAssertEqual(story.plays.playCount, 1)
        }
    }

    // MARK: - Helpers (copied from SourceVoicesTests and adapted)

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
    /// mirroring SourceVoicesTests / SourceAttributionTests.
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
