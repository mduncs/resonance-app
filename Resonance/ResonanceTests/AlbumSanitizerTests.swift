import XCTest
@testable import Resonance

final class AlbumSanitizerTests: XCTestCase {

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

    func testIsValidRejectsSymbolOnlyNames() {
        let invalidNames = ["+", "?", "…", "•", "–", "—", "-", "*", "/", "\\"]

        for name in invalidNames {
            let album = makeAlbum(name: name)
            XCTAssertFalse(AlbumSanitizer.isValid(album), "Should reject '\(name)'")
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

    func testSanitizeRemovesDuplicates() {
        let albums = [
            makeAlbum(id: "1", name: "Abbey Road", artist: "The Beatles", genre: "Rock", coverArt: "cover1"),
            makeAlbum(id: "2", name: "Abbey Road", artist: "The Beatles", coverArt: "cover2"),
            makeAlbum(id: "3", name: "abbey road", artist: "the beatles"),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.count, 1, "Should deduplicate to 1 album")
    }

    func testSanitizeKeepsBestQuality() {
        let albums = [
            makeAlbum(id: "1", name: "Test", duration: 0, year: nil),
            makeAlbum(id: "2", name: "Test", duration: 3600, year: 2020, genre: "Rock", coverArt: "cover"),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized.first?.id, "2", "Should keep the one with more metadata")
    }

    func testSanitizeFiltersInvalid() {
        let albums = [
            makeAlbum(id: "1", name: "+"),
            makeAlbum(id: "2", name: "Valid Album"),
            makeAlbum(id: "3", name: ""),
        ]

        let sanitized = AlbumSanitizer.sanitize(albums)

        XCTAssertEqual(sanitized.count, 1)
        XCTAssertEqual(sanitized.first?.name, "Valid Album")
    }

    // MARK: - Normalization Tests

    func testNormalizedKeyIgnoresCase() {
        let album1 = makeAlbum(name: "ABBEY ROAD", artist: "THE BEATLES")
        let album2 = makeAlbum(name: "abbey road", artist: "the beatles")

        let key1 = AlbumSanitizer.normalizedKey(for: album1)
        let key2 = AlbumSanitizer.normalizedKey(for: album2)

        XCTAssertEqual(key1, key2)
    }

    func testNormalizedKeyIgnoresDiacritics() {
        let album1 = makeAlbum(name: "Café", artist: "Beyoncé")
        let album2 = makeAlbum(name: "Cafe", artist: "Beyonce")

        let key1 = AlbumSanitizer.normalizedKey(for: album1)
        let key2 = AlbumSanitizer.normalizedKey(for: album2)

        XCTAssertEqual(key1, key2)
    }
}
