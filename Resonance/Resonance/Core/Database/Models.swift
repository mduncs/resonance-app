import Foundation

// MARK: - API Response Models (DTOs)

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
