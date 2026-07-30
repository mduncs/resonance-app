import Foundation

/// Type of pinnable item for quick sidebar access
enum PinnableType: String, Codable, Sendable {
    case album
    case playlist
    case artist
}

/// A pinned item for quick sidebar access
/// Local-only (Navidrome has no pins API)
struct PinnedItem: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let type: PinnableType
    let name: String
    let coverArtId: String?
    let createdAt: Date

    init(id: String, type: PinnableType, name: String, coverArtId: String?, createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.name = name
        self.coverArtId = coverArtId
        self.createdAt = createdAt
    }

    // Convenience initializers from models
    init(album: Album) {
        self.init(
            id: album.id,
            type: .album,
            name: album.name,
            coverArtId: album.coverArt
        )
    }

    init(playlist: Playlist) {
        self.init(
            id: playlist.id,
            type: .playlist,
            name: playlist.name,
            coverArtId: playlist.coverArt
        )
    }

    init(artist: Artist) {
        self.init(
            id: artist.id,
            type: .artist,
            name: artist.name,
            coverArtId: artist.coverArt
        )
    }
}
