import Foundation

// MARK: - API Response Models (DTOs)

/// OpenSubsonic ItemDate keeps its reported precision: a year is not January 1.
struct MediaReleaseDate: Codable, Sendable, Hashable, Comparable {
    var year: Int?
    var month: Int?
    var day: Int?

    init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year; self.month = month; self.day = day
    }

    init?(storageValue: String?) {
        guard let storageValue else { return nil }
        let parts = storageValue.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let year = Int(parts[0]) else { return nil }
        self.init(year: year,
                  month: parts.count > 1 ? Int(parts[1]) : nil,
                  day: parts.count > 2 ? Int(parts[2]) : nil)
        guard self.storageValue == storageValue else { return nil }
    }

    var storageValue: String? {
        guard let year, (1...9999).contains(year) else { return nil }
        let prefix = String(format: "%04d", year)
        guard let month, month != 0 else {
            return day == nil || day == 0 ? prefix : nil
        }
        guard (1...12).contains(month) else { return nil }
        let yearMonth = prefix + String(format: "-%02d", month)
        guard let day, day != 0 else { return yearMonth }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else { return nil }
        return yearMonth + String(format: "-%02d", day)
    }

    var displayValue: String {
        formattedValue(long: false)
    }

    /// Album credits use a written month; tables use a compact numeric date.
    var summaryDisplayValue: String {
        formattedValue(long: true)
    }

    private func formattedValue(long: Bool) -> String {
        guard let stored = storageValue else { return "" }
        let parts = stored.split(separator: "-")
        guard parts.count == 3 else { return stored }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return "" }
        var style = Date.FormatStyle(date: long ? .long : .numeric, time: .omitted)
        if !long { style = style.year(.twoDigits) }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.storageValue ?? "") < (rhs.storageValue ?? "")
    }
}

struct Server: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var url: URL
    var username: String
    // Password stored in Keychain, not here

    init(id: UUID = UUID(), name: String, url: URL, username: String) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
    }
}

struct Artist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    let albumCount: Int
    let coverArt: String?
    var starred: Date?

    static let placeholder = Artist(
        id: "placeholder",
        name: "Artist Name",
        albumCount: 10,
        coverArt: nil,
        starred: nil
    )
}

struct Album: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    let artist: String
    let artistId: String
    let songCount: Int
    let duration: Int
    let year: Int?
    let genre: String?
    let coverArt: String?
    var starred: Date?
    var rating: Int?

    /// Server-reported date the album was added (OpenSubsonic AlbumID3.created).
    /// Unknown for older caches and synthetic albums; never derived from release year.
    var addedAt: Date? = nil
    var releaseDate: MediaReleaseDate? = nil

    static let placeholder = Album(
        id: "placeholder",
        name: "Album Name",
        artist: "Artist Name",
        artistId: "artist-id",
        songCount: 12,
        duration: 3600,
        year: 2024,
        genre: "Rock",
        coverArt: nil,
        starred: nil,
        rating: nil
    )
}

struct Song: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let title: String
    let album: String
    let albumId: String
    let artist: String
    let artistId: String
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let duration: Int // seconds
    let bitRate: Int?
    let contentType: String
    let suffix: String
    let coverArt: String?
    var starred: Date?
    var rating: Int?
    var replayGain: ReplayGain?
    var isExplicit: Bool = false
    /// Navidrome/Subsonic file path, relative to the music-folder root.
    /// Decode-only; used to join songs to Fetcher source-attribution provenance.
    var path: String?
    /// Server-reported plays; nil means the server has not supplied a count.
    var playCount: Int? = nil
    /// Server media-created timestamp (Child.created), not local admission or cache time.
    var addedAt: Date? = nil
    /// Reported album release date, when available; never inferred from `year`.
    var releaseDate: MediaReleaseDate? = nil
    /// nil = unsupported/unknown, [] = server reports no grouping tags.
    var groupings: [String]? = nil

    var groupingDisplay: String {
        (groupings ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "; ")
    }

    var groupingsStorage: String? {
        guard let groupings, let data = try? JSONEncoder().encode(groupings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeGroupings(_ storage: String?) -> [String]? {
        guard let data = storage?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Untagged or nonpositive discs belong with disc 1 when presenting an album.
    /// Keep the original metadata intact for other uses.
    var effectiveAlbumDiscNumber: Int {
        max(1, discNumber ?? 1)
    }

    var formattedDuration: String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static let placeholder = Song(
        id: "placeholder",
        title: "Song Title",
        album: "Album Name",
        albumId: "album-id",
        artist: "Artist Name",
        artistId: "artist-id",
        track: 1,
        discNumber: 1,
        year: 2024,
        genre: "Rock",
        duration: 240,
        bitRate: 320,
        contentType: "audio/mpeg",
        suffix: "mp3",
        coverArt: nil,
        starred: nil,
        rating: nil,
        replayGain: nil
    )
}

extension Array where Element == Song {
    /// Album order, including older imports with absent disc tags. Unknown track
    /// numbers follow numbered tracks; ties retain the server's original order.
    func sortedForAlbum() -> [Song] {
        enumerated().sorted { lhs, rhs in
            let leftDisc = lhs.element.effectiveAlbumDiscNumber
            let rightDisc = rhs.element.effectiveAlbumDiscNumber
            if leftDisc != rightDisc {
                return leftDisc < rightDisc
            }

            let leftTrack = lhs.element.track.flatMap { $0 > 0 ? $0 : nil }
            let rightTrack = rhs.element.track.flatMap { $0 > 0 ? $0 : nil }
            switch (leftTrack, rightTrack) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

struct ReplayGain: Codable, Sendable, Hashable {
    let trackGain: Float?
    let albumGain: Float?
    let trackPeak: Float?
    let albumPeak: Float?
}

struct Playlist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    var comment: String?
    let owner: String
    let songCount: Int
    let duration: Int
    let created: Date
    let changed: Date
    let coverArt: String?
    let isPublic: Bool

    var formattedDuration: String {
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }

    static let placeholder = Playlist(
        id: "placeholder",
        name: "Playlist Name",
        comment: nil,
        owner: "user",
        songCount: 25,
        duration: 5400,
        created: Date(),
        changed: Date(),
        coverArt: nil,
        isPublic: false
    )
}

struct Genre: Identifiable, Codable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let songCount: Int
    let albumCount: Int
}

struct MusicFolder: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
}

struct MusicDirectory: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let parent: String?
    let children: [DirectoryChild]
}

enum DirectoryChild: Codable, Sendable, Identifiable {
    case folder(MusicFolder)
    case song(Song)

    var id: String {
        switch self {
        case .folder(let folder): return folder.id
        case .song(let song): return song.id
        }
    }
}

// MARK: - Queue Item

struct QueueItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let song: Song
    var playedAt: Date?

    init(id: UUID = UUID(), song: Song, playedAt: Date? = nil) {
        self.id = id
        self.song = song
        self.playedAt = playedAt
    }
}

// MARK: - Lyrics

struct LyricLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: TimeInterval?
    let text: String
    let isBackground: Bool

    init(timestamp: TimeInterval? = nil, text: String, isBackground: Bool = false) {
        self.timestamp = timestamp
        self.text = text
        self.isBackground = isBackground
    }
}

struct Lyrics: Sendable {
    let lines: [LyricLine]
    let isSynced: Bool

    var isEmpty: Bool { lines.isEmpty }

    static let empty = Lyrics(lines: [], isSynced: false)
}

// MARK: - Internet Radio

struct InternetRadioStation: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    let streamUrl: URL
    let homePageUrl: URL?
}
