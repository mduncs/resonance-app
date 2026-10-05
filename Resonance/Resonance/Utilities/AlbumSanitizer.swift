import Foundation

/// Removes repeated native identities without guessing release equivalence.
struct AlbumSanitizer {
    /// Names, artists and metadata completeness do not establish album identity.
    /// Distinct server IDs may be editions or fragments containing unique tracks.
    /// Keep their original order; only repeated IDs represent the same result.
    static func sanitize(_ albums: [Album]) -> [Album] {
        var positions: [String: Int] = [:]
        var result: [Album] = []
        result.reserveCapacity(albums.count)

        for album in albums {
            guard isValid(album) else { continue }

            if let position = positions[album.id] {
                if qualityScore(for: album) > qualityScore(for: result[position]) {
                    result[position] = album
                }
            } else {
                positions[album.id] = result.count
                result.append(album)
            }
        }

        return result
    }

    /// Checks if an album has valid, displayable data
    static func isValid(_ album: Album) -> Bool {
        let trimmed = album.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Symbol-only titles are valid release names, not parsing-failure proof.
        return !trimmed.isEmpty
    }

    /// Scores album metadata completeness - higher = better
    static func qualityScore(for album: Album) -> Int {
        var score = 0

        // prefer albums with metadata
        if album.year != nil { score += 2 }
        if album.genre != nil { score += 1 }
        if let coverArt = album.coverArt, !coverArt.isEmpty { score += 2 }

        // prefer albums with more songs (up to 5 points)
        score += min(album.songCount / 3, 5)

        return score
    }
}
