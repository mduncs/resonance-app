import Foundation

/// Imports metadata from Apple Music Library.xml into Resonance's GRDB database.
/// Handles the two-tier liked/loved distinction:
///   - Tracks with "Date Added" → liked_items (Resonance-only)
///   - Tracks with "Loved: true" → liked_items (Resonance-only; does not star Navidrome)
///   - Tracks with "Play Count" → play_history
struct AppleMusicImporter {
    let databaseManager: DatabaseManager

    struct ImportResult: Sendable {
        var totalTracks: Int = 0
        var matchedLiked: Int = 0
        var matchedLoved: Int = 0
        var matchedPlayHistory: Int = 0
        var unmatched: [(title: String, artist: String)] = []
    }

    struct AppleMusicTrack {
        let name: String
        let artist: String
        let album: String
        let genre: String?
        let year: Int?
        let duration: Int // milliseconds
        let dateAdded: Date?
        let isLoved: Bool
        let playCount: Int?
        let lastPlayDate: Date?
        let trackNumber: Int?
    }

    /// Parse Library.xml and return extracted tracks
    func parseLibraryXML(at path: URL) throws -> [AppleMusicTrack] {
        let data = try Data(contentsOf: path)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: [String: Any]] else {
            throw ImportError.invalidFormat
        }

        var result: [AppleMusicTrack] = []

        for (_, trackDict) in tracks {
            guard let name = trackDict["Name"] as? String,
                  let artist = trackDict["Artist"] as? String else {
                continue
            }

            let dateAdded = trackDict["Date Added"] as? Date
            let isLoved = (trackDict["Loved"] as? Bool) == true
            let playCount = trackDict["Play Count"] as? Int
            let lastPlayDate = trackDict["Play Date UTC"] as? Date

            // Skip tracks that have no useful metadata to import
            if dateAdded == nil && !isLoved && playCount == nil {
                continue
            }

            let track = AppleMusicTrack(
                name: name,
                artist: artist,
                album: (trackDict["Album"] as? String) ?? "",
                genre: trackDict["Genre"] as? String,
                year: trackDict["Year"] as? Int,
                duration: (trackDict["Total Time"] as? Int) ?? 0,
                dateAdded: dateAdded,
                isLoved: isLoved,
                playCount: playCount,
                lastPlayDate: lastPlayDate,
                trackNumber: trackDict["Track Number"] as? Int
            )
            result.append(track)
        }

        return result
    }

    /// Match Apple Music tracks against navidrome songs in the GRDB cache.
    /// Uses normalized title+artist matching with duration as tiebreaker.
    func importLibrary(xmlPath: URL, serverId: String, importLiked: Bool = true, importLoved: Bool = true, importPlayHistory: Bool = true) throws -> ImportResult {
        let tracks = try parseLibraryXML(at: xmlPath)

        // Load all cached songs for matching
        let allSongs = try databaseManager.loadAllSongs(serverId: serverId)

        // Build a lookup index: normalized "artist|||title" → [Song]
        var songIndex: [String: [Song]] = [:]
        for song in allSongs {
            let key = normalizeForMatch("\(song.artist)||||\(song.title)")
            songIndex[key, default: []].append(song)
        }

        var result = ImportResult()
        result.totalTracks = tracks.count

        var likedItems: [(id: String, type: String, likedAt: Date, source: String)] = []
        var lovedItems: [(id: String, type: String, likedAt: Date, source: String)] = []
        var historyItems: [(songId: String, playedAt: Date, count: Int, title: String, artist: String, album: String, albumId: String, coverArt: String?)] = []

        for track in tracks {
            let key = normalizeForMatch("\(track.artist)||||\(track.name)")

            // Try exact normalized match first
            var matched = songIndex[key]?.first

            // Fallback: try matching without album artist differences
            if matched == nil {
                // Try with just the first artist name (before " & ", " feat.", etc.)
                let simpleArtist = simplifyArtist(track.artist)
                let simpleKey = normalizeForMatch("\(simpleArtist)||||\(track.name)")
                matched = songIndex[simpleKey]?.first

                // Try matching any song with same title and duration within 3s
                if matched == nil {
                    let normalizedTitle = normalizeForMatch(track.name)
                    let durationSec = track.duration / 1000
                    matched = allSongs.first { song in
                        normalizeForMatch(song.title) == normalizedTitle &&
                        abs(song.duration - durationSec) <= 3
                    }
                }
            }

            guard let song = matched else {
                result.unmatched.append((title: track.name, artist: track.artist))
                continue
            }

            // Import liked status
            if importLiked, let dateAdded = track.dateAdded {
                likedItems.append((id: song.id, type: "song", likedAt: dateAdded, source: "apple_music"))
                result.matchedLiked += 1
            }

            // Import loved status
            if importLoved, track.isLoved {
                // Keep Apple Music "Loved" local-only for 1.0. Navidrome starred state is
                // reconciled from the server API, so importing into starred_items here would
                // be misleading and can be undone on the next refresh.
                let likedAt = track.dateAdded ?? Date()
                lovedItems.append((id: song.id, type: "song", likedAt: likedAt, source: "apple_music_loved"))
                result.matchedLoved += 1
            }

            // Import play history
            if importPlayHistory, let playCount = track.playCount, playCount > 0, let lastPlayed = track.lastPlayDate {
                historyItems.append((
                    songId: song.id,
                    playedAt: lastPlayed,
                    count: playCount,
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    albumId: song.albumId,
                    coverArt: song.coverArt
                ))
                result.matchedPlayHistory += 1
            }
        }

        // Batch write to database
        if !likedItems.isEmpty {
            try databaseManager.bulkImportLikedItems(items: likedItems, serverId: serverId)
        }

        if !lovedItems.isEmpty {
            try databaseManager.bulkImportLikedItems(items: lovedItems, serverId: serverId)
        }

        if !historyItems.isEmpty {
            try databaseManager.bulkImportPlayHistory(items: historyItems, serverId: serverId)
        }

        return result
    }

    // MARK: - Matching helpers

    /// Normalize a string for fuzzy matching: lowercase, strip diacritics, remove punctuation
    private func normalizeForMatch(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Simplify artist name by taking only the primary artist
    private func simplifyArtist(_ artist: String) -> String {
        // Split on common separators: " & ", " feat.", " ft.", " x ", ", "
        let separators = [" & ", " feat. ", " feat ", " ft. ", " ft ", " x ", ", ", " and "]
        var simple = artist
        for sep in separators {
            if let range = simple.range(of: sep, options: .caseInsensitive) {
                simple = String(simple[..<range.lowerBound])
            }
        }
        return simple
    }

    enum ImportError: LocalizedError {
        case invalidFormat
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Library.xml is not a valid Apple Music library file"
            case .fileNotFound: return "Library.xml not found"
            }
        }
    }
}
