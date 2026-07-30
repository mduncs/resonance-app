import XCTest
@testable import Resonance

final class LyricsServiceTests: XCTestCase {
    
    // MARK: - LRCLIB Response Parsing
    
    func testLRCLibResponseDecoding() throws {
        let json = """
        {
            "id": 123,
            "trackName": "Test Song",
            "artistName": "Test Artist",
            "albumName": "Test Album",
            "duration": 180.5,
            "instrumental": false,
            "plainLyrics": "Line 1\\nLine 2\\nLine 3",
            "syncedLyrics": "[00:12.34] Line 1\\n[00:24.56] Line 2\\n[00:36.78] Line 3"
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(LRCLibResponse.self, from: json)
        
        XCTAssertEqual(response.id, 123)
        XCTAssertEqual(response.trackName, "Test Song")
        XCTAssertEqual(response.artistName, "Test Artist")
        XCTAssertEqual(response.albumName, "Test Album")
        XCTAssertEqual(response.duration, 180.5)
        XCTAssertEqual(response.instrumental, false)
        XCTAssertNotNil(response.plainLyrics)
        XCTAssertNotNil(response.syncedLyrics)
    }
    
    func testLRCLibResponseInstrumental() throws {
        let json = """
        {
            "id": 456,
            "trackName": "Instrumental Track",
            "artistName": "Artist",
            "instrumental": true
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(LRCLibResponse.self, from: json)
        
        XCTAssertEqual(response.instrumental, true)
        XCTAssertNil(response.plainLyrics)
        XCTAssertNil(response.syncedLyrics)
    }
    
    // MARK: - CachedLyrics
    
    func testCachedLyricsCoding() throws {
        let original = CachedLyrics(
            songId: "song123",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Test",
            plainLyrics: "Test",
            fetchedAt: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CachedLyrics.self, from: data)
        
        XCTAssertEqual(decoded.songId, original.songId)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.syncedLyrics, original.syncedLyrics)
        XCTAssertEqual(decoded.plainLyrics, original.plainLyrics)
    }
    
    func testCachedLyricsIsNotFound() {
        let notFound = CachedLyrics(
            songId: "song1",
            source: .notFound,
            syncedLyrics: nil,
            plainLyrics: nil,
            fetchedAt: Date()
        )
        XCTAssertTrue(notFound.isNotFound)

        let found = CachedLyrics(
            songId: "song2",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Lyrics",
            plainLyrics: nil,
            fetchedAt: Date()
        )
        XCTAssertFalse(found.isNotFound)
    }

    func testCachedLyricsValidity() {
        let recentNotFound = CachedLyrics.notFound(songId: "song1")
        XCTAssertTrue(recentNotFound.isValid(ttl: 86400), "Recent not-found should be valid")

        let foundLyrics = CachedLyrics(
            songId: "song2",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Test",
            plainLyrics: nil,
            fetchedAt: Date.distantPast
        )
        XCTAssertTrue(foundLyrics.isValid(), "Found lyrics should always be valid")
    }
    
    // MARK: - LyricsSource
    
    func testLyricsSourceCoding() throws {
        let sources: [LyricsSource] = [.navidrome, .lrclib, .notFound]
        
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(LyricsSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }
}
