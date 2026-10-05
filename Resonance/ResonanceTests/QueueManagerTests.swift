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

    func testLargeSequentialNavigationSnapshotsHistoryByPrefixNotArrayCopy() {
        // These sizes exercise the production library scale without running
        // the previous quadratic implementation as a comparison baseline.
        for count in [1_000, 10_000, 100_000] {
            let manager = QueueManager()
            manager.play(makeSongs(count: count))

            for _ in 1..<count {
                XCTAssertNotNil(manager.next())
            }

            XCTAssertEqual(manager.history.count, count - 1)
            XCTAssertEqual(manager.scalabilityProbe.snapshotsCreated, count - 1)
            XCTAssertEqual(
                manager.scalabilityProbe.historyPrefixCountTotal,
                (count - 1) * (count - 2) / 2
            )
            XCTAssertEqual(manager.scalabilityProbe.sectionMaterializations, 0)
        }
    }

    func testSkippedManualHistoryRestoresTheUnconsumedCursor() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 3))
        manager.addToQueue([makeSong(id: 100), makeSong(id: 101), makeSong(id: 102)])

        let target = try XCTUnwrap(manager.upNextItems.first { $0.song.id == "song-102" })
        XCTAssertEqual(manager.skipTo(id: target.id)?.song.id, "song-102")
        XCTAssertEqual(manager.history.map(\.song.id), ["song-0", "song-100", "song-101"])

        let skipped = try XCTUnwrap(manager.history.first { $0.song.id == "song-100" })
        XCTAssertEqual(manager.restoreHistoryItem(id: skipped.id)?.song.id, "song-100")
        XCTAssertEqual(manager.upcomingItems(limit: 4).map(\.song.id), ["song-101", "song-102", "song-1", "song-2"])
    }

    func testCursorBackedManualSectionSupportsStructuralEditsAndSongUpdates() {
        let manager = QueueManager()
        manager.play(makeSongs(count: 2))
        manager.addToQueue([makeSong(id: 10), makeSong(id: 11), makeSong(id: 12)])
        XCTAssertEqual(manager.next()?.song.id, "song-10")

        manager.addToQueue(makeSong(id: 13))
        manager.moveUpNext(from: IndexSet(integer: 2), to: 0)
        manager.removeFromUpNext(at: 1)
        manager.updateSongStarred(id: "song-13", starred: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(manager.upNextItems.map(\.song.id), ["song-13", "song-12"])
        XCTAssertNotNil(manager.upNextItems.first?.song.starred)
        XCTAssertEqual(manager.scalabilityProbe.sectionMaterializations, 1)
    }

    func testDuplicateSongOccurrencesRemainDistinctAcrossSkipAndRestore() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 2))
        let duplicate = makeSong(id: 42)
        manager.addToQueue([duplicate, duplicate])
        let occurrences = Array(manager.upNextItems)
        XCTAssertNotEqual(occurrences[0].id, occurrences[1].id)

        XCTAssertEqual(manager.skipTo(id: occurrences[1].id)?.id, occurrences[1].id)
        XCTAssertEqual(manager.restoreHistoryItem(id: occurrences[0].id)?.id, occurrences[0].id)
        XCTAssertEqual(manager.next()?.id, occurrences[1].id)
    }

    func testSkippedAutoplayHistoryRestoresCursorAndManualPriority() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 1))
        manager.addToQueue(makeSong(id: 90))
        manager.setAutoPlayItems([makeSong(id: 100), makeSong(id: 101), makeSong(id: 102)])
        let autoplay = Array(manager.autoPlayItems)

        XCTAssertEqual(manager.skipTo(id: autoplay[2].id)?.id, autoplay[2].id)
        let skipped = try XCTUnwrap(manager.history.first { $0.id == autoplay[0].id })
        XCTAssertEqual(manager.restoreHistoryItem(id: skipped.id)?.id, autoplay[0].id)
        XCTAssertEqual(manager.upcomingItems(limit: 4).map(\.song.id), ["song-90", "song-101", "song-102"])
    }

    func testLargeManualSkipSharesSectionStorageAndRestoresTarget() throws {
        let manager = QueueManager()
        manager.play(makeSongs(count: 1))
        manager.addToQueue(makeSongs(count: 10_000))
        let target = manager.upNextItems[9_999]

        XCTAssertEqual(manager.skipTo(id: target.id)?.id, target.id)
        XCTAssertEqual(manager.history.count, 10_000)
        XCTAssertEqual(manager.scalabilityProbe.sectionMaterializations, 0)

        let earlier = try XCTUnwrap(manager.history.first { $0.song.id == "song-5000" })
        XCTAssertEqual(manager.restoreHistoryItem(id: earlier.id)?.song.id, "song-5000")
        XCTAssertEqual(manager.next()?.song.id, "song-5001")
    }

    func testShufflePreservesOccurrencesForSingleAndMixedArtistBuckets() {
        for artistCount in [1, 7] {
            let manager = QueueManager()
            let songs = (0..<10_000).map { index in
                makeSong(id: index, artist: "Artist \(index % artistCount)")
            }
            manager.play(songs)
            let originalIds = Set(manager.baseItems.map(\.id))

            manager.toggleShuffle()
            XCTAssertEqual(Set(manager.baseItems.map(\.id)), originalIds)
            XCTAssertEqual(manager.baseItems.count, songs.count)
            manager.toggleShuffle()
            XCTAssertEqual(Set(manager.baseItems.map(\.id)), originalIds)
            XCTAssertEqual(manager.baseItems.count, songs.count)
        }
    }

    private func makeSongs(count: Int) -> [Song] {
        (0..<count).map { makeSong(id: $0) }
    }

    private func makeSong(id: Int, artist: String = "Artist") -> Song {
        Song(
            id: "song-\(id)",
            title: "Song \(id)",
            album: "Album",
            albumId: "album",
            artist: artist,
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
