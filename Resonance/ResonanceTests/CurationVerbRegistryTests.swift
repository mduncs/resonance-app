import Foundation
import XCTest
@testable import Resonance

/// Covers the OP-3 verb registry: the pinned deck shape, and the extracted
/// write helpers that are the single source of truth for curation writes.
///
/// Coverage honesty: the DB-layer helpers (`captureSong`, `cycleAttentionMark`,
/// `admitSong`, `rejectSong`, `toggleLike`, `markCaptureSource`,
/// `addSongToProject`) are exercised end-to-end against a temporary
/// `DatabaseManager`. Verbs whose behavior needs `AppState`/network (favorite
/// sync, the sheet-opening UI verbs) are covered structurally here — registry
/// shape and availability — because their side effects are `@MainActor`
/// app-state mutations, not database writes.
@MainActor
final class CurationVerbRegistryTests: XCTestCase {

    // MARK: - Pinned registry shape

    func testDeckVerbsMatchPinnedShape() {
        let deck = CurationVerbRegistry.deckVerbs()

        XCTAssertEqual(deck.count, 4)
        XCTAssertEqual(deck.map(\.id), ["capture", "mark", "project", "admit"])
        XCTAssertEqual(deck.map(\.title), ["Capture", "Mark", "Project", "Admit"])
        XCTAssertEqual(deck.map(\.keyHint), ["K", "M", "P", "A"])
        XCTAssertEqual(deck.map(\.isPrimary), [false, false, false, true])
    }

    func testAllVerbsExtendDeckWithQuickCaptureTail() {
        let all = CurationVerbRegistry.allVerbs()

        XCTAssertEqual(
            all.map(\.id),
            [
                "capture", "mark", "project", "admit",
                "like", "favorite", "later", "interesting",
                "add-to-playlist", "more-like-this", "get-info", "reject", "delete"
            ]
        )
        // Look-up dispatch used by QuickCaptureMenu resolves each tail verb.
        for id in ["admit", "like", "favorite", "later", "interesting",
                   "add-to-playlist", "more-like-this", "get-info", "reject", "delete"] {
            XCTAssertNotNil(CurationVerbRegistry.verb(id: id), "missing verb \(id)")
        }
        XCTAssertNil(CurationVerbRegistry.verb(id: "does-not-exist"))
    }

    func testAdmitRequiresActiveServerWhileCaptureDoesNot() throws {
        try withTemporaryUserHome {
            let appState = AppState()
            XCTAssertNil(appState.activeServerId)

            let context = CurationVerbContext(appState: appState, song: makeSong(id: "song-avail"), album: nil)
            let deck = CurationVerbRegistry.deckVerbs()

            let admit = try XCTUnwrap(deck.first { $0.id == "admit" })
            let capture = try XCTUnwrap(deck.first { $0.id == "capture" })

            XCTAssertFalse(admit.isAvailable(context), "admit should be unavailable without an active server")
            XCTAssertTrue(capture.isAvailable(context), "capture only needs a subject")
        }
    }

    // MARK: - Capture

    func testCaptureStagesUnheardWaitingRoomRowWithoutLibraryMembership() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-capture"
            let song = makeSong(id: "song-captured")

            try CurationVerbRegistry.captureSong(song, serverId: serverId, database: database)

            let item = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)
            XCTAssertEqual(item.state, .unheard)
            XCTAssertEqual(item.source, "capture")
            // Capture must not admit the song to the library.
            XCTAssertFalse(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
        }
    }

    // MARK: - Mark cycle

    func testMarkCyclesNoneLovedInterestingNone() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-mark-cycle"
            let song = makeSong(id: "song-marked")

            func loved() throws -> Bool {
                try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .loved)
            }
            func interesting() throws -> Bool {
                try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .interesting)
            }

            XCTAssertFalse(try loved())
            XCTAssertFalse(try interesting())

            let first = try CurationVerbRegistry.cycleAttentionMark(song, serverId: serverId, database: database)
            XCTAssertEqual(first, .loved)
            XCTAssertTrue(try loved())
            XCTAssertFalse(try interesting())

            let second = try CurationVerbRegistry.cycleAttentionMark(song, serverId: serverId, database: database)
            XCTAssertEqual(second, .interesting)
            XCTAssertFalse(try loved())
            XCTAssertTrue(try interesting())

            let third = try CurationVerbRegistry.cycleAttentionMark(song, serverId: serverId, database: database)
            XCTAssertNil(third)
            XCTAssertFalse(try loved())
            XCTAssertFalse(try interesting())
        }
    }

    // MARK: - Admit

    func testAdmitCreatesMembershipAndAdmittedWaitingRoomState() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-admit"
            let song = makeSong(id: "song-admitted")

            try CurationVerbRegistry.admitSong(song, serverId: serverId, database: database)

            XCTAssertTrue(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
            XCTAssertTrue(try database.isInLibrary(id: song.albumId, type: .album, serverId: serverId))
            XCTAssertTrue(try database.isInLibrary(id: song.artistId, type: .artist, serverId: serverId))

            let item = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)
            XCTAssertEqual(item.state, .admitted)
            XCTAssertFalse(try database.isHidden(id: song.id, type: "song", serverId: serverId))
        }
    }

    // MARK: - Reject / Like / Later-Interesting / Project (extracted writes)

    func testRejectHidesRemovesAndTerminatesInWaitingRoom() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-reject"
            let song = makeSong(id: "song-rejected")

            try CurationVerbRegistry.admitSong(song, serverId: serverId, database: database)
            try CurationVerbRegistry.rejectSong(song, serverId: serverId, database: database)

            XCTAssertFalse(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
            XCTAssertTrue(try database.isHidden(id: song.id, type: "song", serverId: serverId))
            let item = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)
            XCTAssertEqual(item.state, .rejected)
        }
    }

    func testToggleLikeFlipsLocalLikeWithoutServerSync() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-like"
            let song = makeSong(id: "song-liked")

            XCTAssertTrue(try CurationVerbRegistry.toggleLike(song, serverId: serverId, database: database))
            XCTAssertTrue(try database.isLiked(id: song.id, type: "song", serverId: serverId))
            XCTAssertTrue(try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .liked))

            XCTAssertFalse(try CurationVerbRegistry.toggleLike(song, serverId: serverId, database: database))
            XCTAssertFalse(try database.isLiked(id: song.id, type: "song", serverId: serverId))
            XCTAssertFalse(try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .liked))
        }
    }

    func testMarkCaptureSourceStagesLaterAndInteresting() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-tail-marks"
            let laterSong = makeSong(id: "song-later")
            let interestingSong = makeSong(id: "song-interesting")

            try CurationVerbRegistry.markCaptureSource(laterSong, source: "quick_capture_later", serverId: serverId, database: database)
            try CurationVerbRegistry.markCaptureSource(interestingSong, source: "quick_capture_interesting", serverId: serverId, database: database)

            XCTAssertTrue(try database.isAttentionMarked(id: laterSong.id, type: .song, serverId: serverId, markType: .later))
            XCTAssertEqual(try waitingRoomItem(in: database, songId: laterSong.id, serverId: serverId).state, .unheard)

            XCTAssertTrue(try database.isAttentionMarked(id: interestingSong.id, type: .song, serverId: serverId, markType: .interesting))
            XCTAssertEqual(try waitingRoomItem(in: database, songId: interestingSong.id, serverId: serverId).state, .interesting)
        }
    }

    func testAddSongToProjectDedupesAndPositions() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-project"
            let song = makeSong(id: "song-project")

            let project = try CurationVerbRegistry.createListeningProject(from: song, serverId: serverId, database: database)
            // Adding the same song again must not duplicate the project item.
            try CurationVerbRegistry.addSongToProject(song, project: project, serverId: serverId, database: database)

            let items = try database.loadProjectItems(projectId: project.id, serverId: serverId)
            XCTAssertEqual(items.map(\.itemId), [song.id])
            XCTAssertEqual(items.map(\.position), [0])
        }
    }

    // MARK: - Fixtures

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Test Song",
            album: "Test Album",
            albumId: "album-1",
            artist: "Test Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Ambient",
            duration: 180,
            bitRate: 320,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )
    }

    private func waitingRoomItem(
        in database: DatabaseManager,
        songId: String,
        serverId: String
    ) throws -> WaitingRoomItem {
        try XCTUnwrap(
            database.loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                .first { $0.song.id == songId }
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
