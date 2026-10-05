import XCTest
@testable import Resonance

final class SearchPagingTests: XCTestCase {
    func testUnrequestedEmptyFacetsStayOpenAndOffsetsUseRawRows() throws {
        var paging = SearchPaging()
        try paging.consume(SearchResults(artists: [artist("a"), artist("a"), artist("b")], albums: [], songs: []), requested: .artists)
        XCTAssertEqual(paging.artistOffset, 3)
        XCTAssertEqual(paging.artists.map(\.id), ["a", "b"])
        XCTAssertTrue(paging.hasMoreAlbums)
        XCTAssertTrue(paging.hasMoreSongs)
    }

    func testShortNonemptyPageRemainsOpenUntilAnEmptyRequestedPage() throws {
        var paging = SearchPaging()
        try paging.consume(SearchResults(artists: [artist("a")], albums: [], songs: []), requested: .artists)
        XCTAssertTrue(paging.hasMoreArtists)
        try paging.consume(SearchResults(artists: [], albums: [], songs: []), requested: .artists)
        XCTAssertFalse(paging.hasMoreArtists)
    }

    func testRepeatedPageFailureDoesNotCommitEarlierFacetMutation() throws {
        var paging = SearchPaging()
        let firstAlbum = album("album-a", artistID: "a")
        try paging.consume(SearchResults(artists: [artist("a")], albums: [firstAlbum], songs: []),
                           requested: [.artists, .albums])
        let duplicate = SearchResults(artists: [], albums: [firstAlbum], songs: [])
        // The first page contains new data. The guard fails on the third
        // consecutive page with no new IDs, not the third page overall.
        try paging.consume(duplicate, requested: .albums)
        try paging.consume(duplicate, requested: .albums)
        let artistOffsetBeforeFailure = paging.artistOffset
        let albumOffsetBeforeFailure = paging.albumOffset
        let failingPage = SearchResults(artists: [artist("new")], albums: [firstAlbum], songs: [])
        XCTAssertThrowsError(try paging.consume(failingPage, requested: [.artists, .albums]))
        XCTAssertEqual(paging.artistOffset, artistOffsetBeforeFailure)
        XCTAssertEqual(paging.albumOffset, albumOffsetBeforeFailure)
        XCTAssertEqual(paging.artists.map(\.id), ["a"])
        XCTAssertEqual(paging.albums.map(\.id), ["album-a"])
    }

    func testFacetRequestCountsHonorOffsetsAndExhaustion() throws {
        var paging = SearchPaging()
        try paging.consume(SearchResults(artists: [], albums: [], songs: []), requested: .albums)
        let counts = paging.requestCounts(artists: true, albums: true, songs: false)
        XCTAssertEqual(counts.0, 100)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testVisibilityProjectsAdmissionAndAllHiddenScopes() {
        let raw = SearchResults(
            artists: [artist("artist-kept"), artist("artist-hidden")],
            albums: [album("album-kept", artistID: "artist-kept"), album("album-hidden-parent", artistID: "artist-hidden")],
            songs: [
                song("song-kept", albumID: "album-kept", artistID: "artist-kept"),
                song("song-hidden-album", albumID: "album-hidden", artistID: "artist-kept"),
                song("song-hidden-artist", albumID: "album-kept", artistID: "artist-hidden")
            ]
        )
        let visibility = SearchResultVisibility(
            libraryOnly: true,
            admittedArtistIDs: ["artist-kept", "artist-hidden"],
            admittedAlbumIDs: ["album-kept", "album-hidden-parent"],
            admittedSongIDs: ["song-kept", "song-hidden-album", "song-hidden-artist"],
            hiddenArtistIDs: ["artist-hidden"],
            hiddenAlbumIDs: ["album-hidden"],
            hiddenSongIDs: []
        )

        let visible = visibility.project(raw)
        XCTAssertEqual(visible.artists.map(\.id), ["artist-kept"])
        XCTAssertEqual(visible.albums.map(\.id), ["album-kept"])
        XCTAssertEqual(visible.songs.map(\.id), ["song-kept"])
    }

    func testGlobalVisibilityDoesNotRequireAdmission() {
        let raw = SearchResults(artists: [artist("a")], albums: [], songs: [])
        let visibility = SearchResultVisibility(
            libraryOnly: false,
            admittedArtistIDs: [], admittedAlbumIDs: [], admittedSongIDs: [],
            hiddenArtistIDs: [], hiddenAlbumIDs: [], hiddenSongIDs: []
        )
        XCTAssertEqual(visibility.project(raw).artists.map(\.id), ["a"])
    }

    private func artist(_ id: String) -> Artist {
        Artist(id: id, name: id, albumCount: 0, coverArt: nil, starred: nil)
    }

    private func album(_ id: String, artistID: String) -> Album {
        Album(id: id, name: id, artist: artistID, artistId: artistID,
              songCount: 0, duration: 0, year: nil, genre: nil,
              coverArt: nil, starred: nil, rating: nil)
    }

    private func song(_ id: String, albumID: String, artistID: String) -> Song {
        Song(id: id, title: id, album: albumID, albumId: albumID,
             artist: artistID, artistId: artistID, track: nil,
             discNumber: nil, year: nil, genre: nil, duration: 1,
             bitRate: nil, contentType: "audio/mpeg", suffix: "mp3",
             coverArt: nil, starred: nil, rating: nil, replayGain: nil)
    }
}
