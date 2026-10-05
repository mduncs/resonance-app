import XCTest
@testable import Resonance

final class AlbumSanitizerTests: XCTestCase {
    func testAlbumAdditionDateSurvivesMappingAndCache() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = Data(#"{"id":"added-date","name":"Album","created":"2026-08-22T12:34:56Z"}"#.utf8)
        let album = try decoder.decode(SubsonicAlbum.self, from: payload).toAlbum()
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T12:34:56Z"))
        XCTAssertEqual(album.addedAt, expected)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseManager(databaseURL: root.appendingPathComponent("test.db"))
        let serverID = UUID().uuidString
        try database.saveAlbums([album], serverId: serverID)
        let restored = try XCTUnwrap(database.loadAlbums(serverId: serverID).first)
        XCTAssertEqual(restored.addedAt, expected)
    }

    func testMissingAlbumAdditionDateStaysUnknown() throws {
        let payload = Data(#"{"id":"unknown-date","name":"Album","year":1999}"#.utf8)
        let album = try JSONDecoder().decode(SubsonicAlbum.self, from: payload).toAlbum()
        XCTAssertNil(album.addedAt)
    }


    // MARK: - Helper

    func makeAlbum(
        id: String = "1",
        name: String = "Album",
        artist: String = "Artist",
        artistId: String = "a1",
        songCount: Int = 10,
        duration: Int = 3600,
        year: Int? = 2020,
        genre: String? = nil,
        coverArt: String? = nil,
        starred: Date? = nil,
        rating: Int? = nil
    ) -> Album {
        Album(
            id: id,
            name: name,
            artist: artist,
            artistId: artistId,
            songCount: songCount,
            duration: duration,
            year: year,
            genre: genre,
            coverArt: coverArt,
            starred: starred,
            rating: rating
        )
    }

    // MARK: - Validation Tests

    func testIsValidRejectsEmptyName() {
        let album = makeAlbum(name: "")
        XCTAssertFalse(AlbumSanitizer.isValid(album))
    }

    func testIsValidPreservesSymbolOnlyReleaseNames() {
        let validNames = ["+", "?", "…", "•", "–", "—", "-", "*", "/", "\\"]

        for name in validNames {
            let album = makeAlbum(name: name)
            XCTAssertTrue(AlbumSanitizer.isValid(album), "Must not hide a release named '\(name)'")
        }
    }

    func testIsValidAcceptsNormalNames() {
        let validNames = ["Abbey Road", "OK Computer", "1989", "...Baby One More Time"]

        for name in validNames {
            let album = makeAlbum(name: name)
            XCTAssertTrue(AlbumSanitizer.isValid(album), "Should accept '\(name)'")
        }
    }

    // MARK: - Deduplication Tests

    func testSanitizePreservesSameNameDistinctReleaseIdentities() {
        let albums = [
            makeAlbum(id: "1", name: "Abbey Road", artist: "The Beatles", genre: "Rock", coverArt: "cover1"),
            makeAlbum(id: "2", name: "Abbey Road", artist: "The Beatles", coverArt: "cover2"),
            makeAlbum(id: "3", name: "abbey road", artist: "the beatles"),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.map(\.id), ["1", "2", "3"], "Names cannot establish edition or release identity")
    }

    func testSanitizeKeepsBestQuality() {
        let albums = [
            makeAlbum(id: "1", name: "Test", duration: 0, year: nil),
            makeAlbum(id: "1", name: "Test", duration: 3600, year: 2020, genre: "Rock", coverArt: "cover"),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized.first?.coverArt, "cover", "May enrich only the same native identity")
    }

    func testSanitizeFiltersInvalid() {
        let albums = [
            makeAlbum(id: "1", name: "  \n"),
            makeAlbum(id: "2", name: "Valid Album"),
            makeAlbum(id: "3", name: ""),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized.first?.name, "Valid Album")
    }

    func testRepeatedNativeIDsDoNotReorderOtherAlbums() {
        let albums = [makeAlbum(id: "z"), makeAlbum(id: "a"), makeAlbum(id: "z", coverArt: "art"), makeAlbum(id: "b")]
        XCTAssertEqual(AlbumSanitizer.sanitize(albums).map(\.id), ["z", "a", "b"])
    }

    func testFragmentsWithDifferentTrackCoverageRemainAccessible() {
        let albums = [makeAlbum(id: "main", name: "DJ Mix", songCount: 20),
                      makeAlbum(id: "single-date-a", name: "DJ Mix", songCount: 1),
                      makeAlbum(id: "single-date-b", name: "DJ Mix", songCount: 1)]
        let sanitized = AlbumSanitizer.sanitize(albums)
        XCTAssertEqual(sanitized.count, 3)
        XCTAssertEqual(sanitized.reduce(0) { $0 + $1.songCount }, 22)
    }
}
