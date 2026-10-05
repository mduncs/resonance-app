import XCTest
@testable import Resonance

final class AlbumSongOrderTests: XCTestCase {
    func testTwoShoesKeepsMiserereAtTrackSixWhenItsDiscTagIsAbsent() {
        // The imported album arrives with untagged Miserere before disc-1 tracks.
        let serverOrder = [6, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11]
        let songs = serverOrder.map { track in
            makeSong(
                id: "track-\(track)",
                title: track == 6 ? "Miserere" : "Track \(track)",
                track: track,
                disc: track == 6 ? nil : 1
            )
        }

        let ordered = songs.sortedForAlbum()

        XCTAssertEqual(ordered.compactMap(\.track), Array(1...11))
        XCTAssertEqual(ordered[5].title, "Miserere")
        XCTAssertNil(ordered[5].discNumber, "Ordering must not rewrite imported metadata")
        XCTAssertEqual(Set(ordered), Set(songs), "Ordering must preserve every song unchanged")
    }

    func testMissingZeroAndNegativeDiscsShareDiscOne() {
        let songs = [
            makeSong(id: "four", track: 4, disc: 1),
            makeSong(id: "three", track: 3, disc: nil),
            makeSong(id: "two", track: 2, disc: 0),
            makeSong(id: "one", track: 1, disc: -1)
        ]

        XCTAssertEqual(songs.map(\.effectiveAlbumDiscNumber), [1, 1, 1, 1])
        XCTAssertEqual(songs.sortedForAlbum().map(\.id), ["one", "two", "three", "four"])
    }

    func testRealDiscsStaySeparateAndSortBeforeTheirTracks() {
        let songs = [
            makeSong(id: "disc-three-one", track: 1, disc: 3),
            makeSong(id: "disc-two-two", track: 2, disc: 2),
            makeSong(id: "disc-one-two", track: 2, disc: nil),
            makeSong(id: "disc-two-one", track: 1, disc: 2),
            makeSong(id: "disc-one-one", track: 1, disc: 1),
            makeSong(id: "disc-one-unknown", track: nil, disc: 0)
        ]

        XCTAssertEqual(songs.sortedForAlbum().map(\.id), [
            "disc-one-one", "disc-one-two", "disc-one-unknown",
            "disc-two-one", "disc-two-two", "disc-three-one"
        ])
    }

    func testTiedAndUnknownTracksKeepTheirOriginalRelativeOrder() {
        let songs = [
            makeSong(id: "unknown-nil", track: nil, disc: nil),
            makeSong(id: "two-first", track: 2, disc: 1),
            makeSong(id: "unknown-zero", track: 0, disc: 0),
            makeSong(id: "one", track: 1, disc: 1),
            makeSong(id: "two-second", track: 2, disc: nil),
            makeSong(id: "unknown-negative", track: -2, disc: 1),
            makeSong(id: "largest-positive", track: Int.max, disc: 1)
        ]

        XCTAssertEqual(songs.sortedForAlbum().map(\.id), [
            "one", "two-first", "two-second", "largest-positive",
            "unknown-nil", "unknown-zero", "unknown-negative"
        ])
    }

    func testEmptyAndEntirelyUnnumberedAlbumsRemainUnchanged() {
        XCTAssertTrue([Song]().sortedForAlbum().isEmpty)
        let songs = [
            makeSong(id: "third", track: nil, disc: nil),
            makeSong(id: "first", track: 0, disc: 1),
            makeSong(id: "second", track: -1, disc: 0)
        ]

        XCTAssertEqual(songs.sortedForAlbum(), songs)
    }

    func testFooterStatsUseFetchedVisibleSongsInsteadOfStaleAlbumMetadata() {
        let fetchedVisible = [
            makeSong(id: "live-one", track: 1, disc: 1, duration: 125),
            makeSong(id: "live-two", track: 2, disc: 1, duration: 185),
            makeSong(id: "live-three", track: 3, disc: 1, duration: 60)
        ]

        let stats = AlbumFooterStats(songs: fetchedVisible)
        XCTAssertEqual(stats.songCount, 3)
        XCTAssertEqual(stats.totalDuration, 370)
        XCTAssertEqual(stats.formattedDuration, "6 min")
    }

    private func makeSong(id: String, title: String = "Song", track: Int?, disc: Int?, duration: Int = 240) -> Song {
        Song(
            id: id,
            title: title,
            album: "Two Shoes",
            albumId: "two-shoes",
            artist: "The Cat Empire",
            artistId: "the-cat-empire",
            track: track,
            discNumber: disc,
            year: nil,
            genre: nil,
            duration: duration,
            bitRate: nil,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )
    }
}
