import XCTest
@testable import Resonance

@MainActor
final class QueueManagerTests: XCTestCase {
    func testLimitedRemainingBaseItemsPreservesPlaybackOrder() {
        let manager = QueueManager()
        manager.play(makeSongs(count: 10), startingAt: 2)

        XCTAssertEqual(manager.remainingBaseCount, 7)
        XCTAssertEqual(
            manager.remainingBaseItems(limit: 3).map(\.song.id),
            ["song-3", "song-4", "song-5"]
        )
    }

    func testUpcomingItemsLimitSpansQueueSectionsInPlaybackOrder() {
        let manager = QueueManager()
        manager.play(makeSongs(count: 5), startingAt: 1)
        manager.playNext(makeSong(id: 100))
        manager.addToQueue(makeSong(id: 101))

        XCTAssertEqual(manager.allUpcomingCount, 5)
        XCTAssertEqual(
            manager.upcomingItems(limit: 4).map(\.song.id),
            ["song-100", "song-101", "song-2", "song-3"]
        )
    }

    func testToggleShuffleOffAfterAdvancingRestoresCurrentAndOriginalUpcomingOrder() throws {
        let manager = QueueManager()
        let songs = makeSongs(count: 6)

        manager.play(songs, startingAt: 0)
        manager.toggleShuffle()

        let advanced = try XCTUnwrap(manager.next())
        let playedIds = manager.history.map(\.song.id) + [advanced.song.id]

        manager.toggleShuffle()

        let expectedUpcoming = songs.map(\.id).filter { !playedIds.contains($0) }

        XCTAssertEqual(manager.currentItem?.id, advanced.id)
        XCTAssertEqual(manager.baseItems.map(\.song.id), playedIds + expectedUpcoming)
        XCTAssertEqual(manager.basePosition, playedIds.count - 1)
        XCTAssertEqual(manager.remainingBaseItems.map(\.song.id), expectedUpcoming)
        XCTAssertEqual(manager.next()?.song.id, expectedUpcoming.first)
    }

    func testRestoreHistoryItemAfterSkippingBaseRestoresQueueState() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 5), startingAt: 0)

        let skippedTargetId = try XCTUnwrap(manager.baseItems[safe: 3]?.id)
        XCTAssertEqual(manager.skipTo(id: skippedTargetId)?.song.id, "song-3")
        XCTAssertEqual(manager.history.map(\.song.id), ["song-0", "song-1", "song-2"])

        let skippedHistoryItem = try XCTUnwrap(manager.history.first(where: { $0.song.id == "song-1" }))
        XCTAssertEqual(manager.restoreHistoryItem(id: skippedHistoryItem.id)?.song.id, "song-1")

        XCTAssertEqual(manager.history.map(\.song.id), ["song-0"])
        XCTAssertEqual(manager.basePosition, 1)
        XCTAssertEqual(manager.remainingBaseItems.map(\.song.id), ["song-2", "song-3", "song-4"])
        XCTAssertEqual(manager.next()?.song.id, "song-2")
    }

    func testRestoreHistoryItemForConsumedUpNextKeepsBaseProgression() {
        let manager = QueueManager()
        manager.play(makeSongs(count: 4), startingAt: 0)
        manager.playNext(makeSong(id: 100))

        XCTAssertEqual(manager.next()?.song.id, "song-100")
        XCTAssertEqual(manager.next()?.song.id, "song-1")

        let upNextHistoryItem = manager.history.first { $0.song.id == "song-100" }
        XCTAssertEqual(manager.restoreHistoryItem(id: upNextHistoryItem?.id ?? UUID())?.song.id, "song-100")

        XCTAssertEqual(manager.history.map(\.song.id), ["song-0"])
        XCTAssertEqual(manager.basePosition, 0)
        XCTAssertEqual(manager.remainingBaseItems.map(\.song.id), ["song-1", "song-2", "song-3"])
        XCTAssertEqual(manager.next()?.song.id, "song-1")
    }

    func testPreviousRestoresConsumedUpNextState() {
        let manager = QueueManager()
        manager.play(makeSongs(count: 4), startingAt: 0)
        manager.playNext(makeSong(id: 100))

        _ = manager.next()
        _ = manager.next()

        XCTAssertEqual(manager.previous()?.song.id, "song-100")
        XCTAssertEqual(manager.history.map(\.song.id), ["song-0"])
        XCTAssertEqual(manager.next()?.song.id, "song-1")
    }

    func testSkipToCurrentItemDoesNotMutateHistory() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 3), startingAt: 1)

        let currentId = try XCTUnwrap(manager.currentItem?.id)
        let currentItem = manager.skipTo(id: currentId)

        XCTAssertEqual(currentItem?.song.id, "song-1")
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertEqual(manager.basePosition, 1)
    }

    private func makeSongs(count: Int) -> [Song] {
        (0..<count).map { makeSong(id: $0) }
    }

    private func makeSong(id: Int) -> Song {
        Song(
            id: "song-\(id)",
            title: "Song \(id)",
            album: "Album",
            albumId: "album",
            artist: "Artist",
            artistId: "artist",
            track: id,
            discNumber: 1,
            year: 2026,
            genre: "Rock",
            duration: 180,
            bitRate: 320,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil,
            isExplicit: false
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
