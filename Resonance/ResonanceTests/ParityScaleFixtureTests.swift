import XCTest
@testable import Resonance

final class ParityScaleFixtureTests: XCTestCase {
    func testLargePlaylistTransportPreservesAllOccurrences() async throws {
        let catalog = ParityFixtureCatalog.scale
        let playlistID = catalog.playlists[2].id
        let network = NetworkActor(catalog: catalog)
        let songs = try await network.fetchPlaylistSongs(playlistId: playlistID)
        XCTAssertEqual(songs.map(\.id), catalog.playlistSongIDsByID[playlistID])
        XCTAssertEqual(songs.count, 50_000)
        XCTAssertEqual(songs[0].id, songs[1].id)
    }

    func testScaleRequiresExplicitAtlasGate() {
        let option = ["RESONANCE_PARITY_LIBRARY_SCALE": "100k"]
        XCTAssertNil(DeterministicCaptureFixture.configuration(environment: option))
        let legacy = DeterministicCaptureFixture.configuration(environment: option.merging(
            ["RESONANCE_CAPTURE_FIXTURE": "now-playing"], uniquingKeysWith: { _, new in new }
        ))
        XCTAssertEqual(legacy?.usesScaleLibrary, false)
        let ordinary = DeterministicCaptureFixture.configuration(environment: [
            "RESONANCE_PARITY_FIXTURE": "atlas"
        ])
        XCTAssertEqual(ordinary?.usesScaleLibrary, false)
        XCTAssertEqual(ordinary?.catalog.songs.count, ParityFixtureCatalog.standard.songs.count)
        let scale = DeterministicCaptureFixture.configuration(environment: option.merging(
            ["RESONANCE_PARITY_FIXTURE": "atlas"], uniquingKeysWith: { _, new in new }
        ))
        XCTAssertEqual(scale?.usesScaleLibrary, true)
        XCTAssertEqual(scale?.catalog.songs.count, 100_000)
    }

    func testScaleCountsReferencesAndPlaylistOccurrences() {
        let catalog = ParityFixtureCatalog.scale
        XCTAssertEqual(catalog.songs.count, 100_000)
        XCTAssertEqual(catalog.albums.count, 32_000)
        XCTAssertEqual(catalog.artists.count, 15_000)
        XCTAssertEqual(catalog.albums.reduce(0) { $0 + $1.songCount }, catalog.songs.count)
        XCTAssertEqual(catalog.artists.reduce(0) { $0 + $1.albumCount }, catalog.albums.count)
        let songs = Set(catalog.songs.map(\.id))
        let albums = Set(catalog.albums.map(\.id))
        let artists = Set(catalog.artists.map(\.id))
        XCTAssertEqual(songs.count, catalog.songs.count)
        XCTAssertEqual(albums.count, catalog.albums.count)
        XCTAssertEqual(artists.count, catalog.artists.count)
        XCTAssertTrue(catalog.songs.allSatisfy {
            albums.contains($0.albumId) && artists.contains($0.artistId)
        })
        XCTAssertTrue(catalog.albums.allSatisfy { artists.contains($0.artistId) })
        let occurrences = catalog.playlistSongIDsByID[catalog.playlists[2].id] ?? []
        XCTAssertEqual(occurrences.count, 50_000)
        XCTAssertEqual(Set(occurrences).count, 25_000)
        XCTAssertEqual(occurrences[0], occurrences[1])
        XCTAssertTrue(occurrences.allSatisfy { songs.contains($0) })
        XCTAssertEqual(catalog.songs.first, ParityFixtureCatalog.standard.songs.first)
        XCTAssertEqual(catalog.albums.first, ParityFixtureCatalog.standard.albums.first)
        XCTAssertEqual(catalog.lyricsBySongID.count, ParityFixtureCatalog.standard.lyricsBySongID.count)
        XCTAssertEqual(catalog.artworkIDs, ParityFixtureCatalog.standard.artworkIDs)
    }
}
