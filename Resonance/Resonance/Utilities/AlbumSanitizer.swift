import Foundation

/// Sanitizes album data by deduplicating and filtering invalid entries
struct AlbumSanitizer {
    /// Deduplicates albums by name+artist and filters invalid entries
    static func sanitize(_ albums: [Album]) -> [Album] {
        var seen: [String: Album] = [:]

        for album in albums {
            guard isValid(album) else { continue }

            let key = normalizedKey(for: album)

            if let existing = seen[key] {
                // keep the higher quality version
                if qualityScore(for: album) > qualityScore(for: existing) {
                    seen[key] = album
                }
            } else {
                seen[key] = album
            }
        }

        return Array(seen.values)
    }

    /// Checks if an album has valid, displayable data
    static func isValid(_ album: Album) -> Bool {
        let trimmed = album.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // reject empty names
        guard !trimmed.isEmpty else { return false }

        // reject symbol-only names (common parsing failures)
        let invalidNames: Set<String> = ["+", "?", "…", "•", "–", "—", "-", "*", "/", "\\"]
        guard !invalidNames.contains(trimmed) else { return false }

        // reject names that are entirely symbols/whitespace/punctuation
        let hasLetterOrNumber = trimmed.contains { $0.isLetter || $0.isNumber }
        guard hasLetterOrNumber else { return false }

        return true
    }

    /// Creates a normalized key for deduplication (case/diacritic insensitive)
    static func normalizedKey(for album: Album) -> String {
        let name = album.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let artist = album.artist
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return "\(name)|\(artist)"
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
