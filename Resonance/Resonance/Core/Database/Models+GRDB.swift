import Foundation
import GRDB

// MARK: - GRDB Record conformances for existing model structs
// These extensions add database persistence without modifying the original DTOs.
// The models remain the API/UI layer; GRDB records are the persistence layer.

// MARK: - Album + GRDB

extension Album: FetchableRecord {
    /// Column mapping for cached_albums table
    enum Columns {
        static let id = Column("id")
        static let serverId = Column("server_id")
        static let name = Column("name")
        static let artistName = Column("artist_name")
        static let artistId = Column("artist_id")
        static let songCount = Column("song_count")
        static let duration = Column("duration")
        static let year = Column("year")
        static let genre = Column("genre")
        static let coverArtId = Column("cover_art_id")
        static let starredAt = Column("starred_at")
        static let rating = Column("rating")
    }

    public init(row: Row) {
        self.init(
            id: row["id"],
            name: row["name"],
            artist: row["artist_name"],
            artistId: row["artist_id"],
            songCount: row["song_count"],
            duration: row["duration"],
            year: row["year"],
            genre: row["genre"],
            coverArt: row["cover_art_id"],
            starred: row["starred_at"],
            rating: row["rating"]
        )
    }
}

// MARK: - Artist + GRDB

extension Artist: FetchableRecord {
    enum Columns {
        static let id = Column("id")
        static let serverId = Column("server_id")
        static let name = Column("name")
        static let albumCount = Column("album_count")
        static let coverArtId = Column("cover_art_id")
        static let starredAt = Column("starred_at")
    }

    public init(row: Row) {
        self.init(
            id: row["id"],
            name: row["name"],
            albumCount: row["album_count"],
            coverArt: row["cover_art_id"],
            starred: row["starred_at"]
        )
    }
}

// MARK: - Song + GRDB

extension Song: FetchableRecord {
    enum Columns {
        static let id = Column("id")
        static let serverId = Column("server_id")
        static let title = Column("title")
        static let albumName = Column("album_name")
        static let albumId = Column("album_id")
        static let artistName = Column("artist_name")
        static let artistId = Column("artist_id")
        static let track = Column("track")
        static let discNumber = Column("disc_number")
        static let year = Column("year")
        static let genre = Column("genre")
        static let duration = Column("duration")
        static let bitRate = Column("bit_rate")
        static let contentType = Column("content_type")
        static let suffix = Column("suffix")
        static let coverArtId = Column("cover_art_id")
        static let starredAt = Column("starred_at")
        static let rating = Column("rating")
    }

    public init(row: Row) {
        self.init(
            id: row["id"],
            title: row["title"],
            album: row["album_name"],
            albumId: row["album_id"],
            artist: row["artist_name"],
            artistId: row["artist_id"],
            track: row["track"],
            discNumber: row["disc_number"],
            year: row["year"],
            genre: row["genre"],
            duration: row["duration"],
            bitRate: row["bit_rate"],
            contentType: row["content_type"],
            suffix: row["suffix"],
            coverArt: row["cover_art_id"],
            starred: row["starred_at"],
            rating: row["rating"],
            replayGain: nil
        )
    }
}

// MARK: - Playlist + GRDB

extension Playlist: FetchableRecord {
    enum Columns {
        static let id = Column("id")
        static let serverId = Column("server_id")
        static let name = Column("name")
        static let comment = Column("comment")
        static let owner = Column("owner")
        static let songCount = Column("song_count")
        static let duration = Column("duration")
        static let created = Column("created")
        static let changed = Column("changed")
        static let coverArtId = Column("cover_art_id")
        static let isPublic = Column("is_public")
    }

    public init(row: Row) {
        self.init(
            id: row["id"],
            name: row["name"],
            comment: row["comment"],
            owner: row["owner"],
            songCount: row["song_count"],
            duration: row["duration"],
            created: row["created"],
            changed: row["changed"],
            coverArt: row["cover_art_id"],
            isPublic: row["is_public"]
        )
    }
}

// MARK: - PlayHistoryEntry + GRDB

extension PlayHistoryEntry: FetchableRecord {
    init(row: Row) {
        self.init(
            id: row["id"],
            songId: row["song_id"],
            serverId: row["server_id"],
            playedAt: row["played_at"],
            durationPlayed: row["duration_played"],
            title: row["title"],
            artist: row["artist"],
            album: row["album"],
            albumId: row["album_id"],
            coverArt: row["cover_art"]
        )
    }
}
