import Foundation

// MARK: - Lyrics Source

enum LyricsSource: String, Codable, Sendable {
    case navidrome
    case lrclib
    case notFound
}

// MARK: - Cached Lyrics

struct CachedLyrics: Codable, Sendable {
    let songId: String
    let source: LyricsSource
    let syncedLyrics: String?
    let plainLyrics: String?
    let fetchedAt: Date

    /// Check if this cache entry represents "no lyrics found"
    var isNotFound: Bool {
        source == .notFound
    }

    /// Check if cache is still valid (not found entries expire after 24h)
    func isValid(ttl: TimeInterval = 86400) -> Bool {
        if isNotFound {
            return Date().timeIntervalSince(fetchedAt) < ttl
        }
        // Found lyrics never expire
        return true
    }

    /// Create a "not found" cache entry
    static func notFound(songId: String) -> CachedLyrics {
        CachedLyrics(
            songId: songId,
            source: .notFound,
            syncedLyrics: nil,
            plainLyrics: nil,
            fetchedAt: Date()
        )
    }
}

// MARK: - LRCLIB API Response

struct LRCLibResponse: Codable, Sendable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}
