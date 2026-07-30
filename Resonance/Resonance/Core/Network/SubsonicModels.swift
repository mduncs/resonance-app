import Foundation

// MARK: - Response Wrapper

struct SubsonicResponse<T: SubsonicContent & Decodable>: Decodable {
    let subsonicResponse: SubsonicResponseBody<T>

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicResponseBody<T: SubsonicContent & Decodable>: Decodable {
    let status: String
    let version: String
    let error: SubsonicErrorBody?
    let content: T?

    enum CodingKeys: String, CodingKey {
        case status, version, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        version = try container.decode(String.self, forKey: .version)
        error = try container.decodeIfPresent(SubsonicErrorBody.self, forKey: .error)

        // Try to decode content from the dynamic key
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        content = try? T(from: dynamicContainer.superDecoder(forKey: DynamicCodingKey(stringValue: T.contentKey)!))
    }
}

struct SubsonicErrorBody: Decodable {
    let code: Int
    let message: String
}

// MARK: - Dynamic Coding Key

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Content Key Protocol

protocol SubsonicContent: Decodable {
    static var contentKey: String { get }
}

// MARK: - Response Types

struct ArtistsResponse: SubsonicContent, Decodable {
    static let contentKey = "artists"
    let index: [ArtistIndex]

    struct ArtistIndex: Decodable {
        let name: String
        let artist: [SubsonicArtist]
    }
}

struct SubsonicArtist: Decodable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let starred: Date?

    func toArtist() -> Artist {
        Artist(
            id: id,
            name: name,
            albumCount: albumCount ?? 0,
            coverArt: coverArt,
            starred: starred
        )
    }
}

struct ArtistResponse: SubsonicContent, Decodable {
    static let contentKey = "artist"
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let starred: Date?
    let album: [SubsonicAlbum]?
}

struct AlbumListResponse: SubsonicContent, Decodable {
    static let contentKey = "albumList2"
    let album: [SubsonicAlbum]?
}

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let starred: Date?
    let userRating: Int?

    func toAlbum() -> Album {
        Album(
            id: id,
            name: name,
            artist: artist ?? "Unknown Artist",
            artistId: artistId ?? "",
            songCount: songCount ?? 0,
            duration: duration ?? 0,
            year: year,
            genre: genre,
            coverArt: coverArt,
            starred: starred,
            rating: userRating
        )
    }
}

struct AlbumResponse: SubsonicContent, Decodable {
    static let contentKey = "album"
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let starred: Date?
    let song: [SubsonicSong]?
}

struct SubsonicSong: Decodable {
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let duration: Int?
    let bitRate: Int?
    let contentType: String?
    let suffix: String?
    let coverArt: String?
    let starred: Date?
    let userRating: Int?
    let replayGain: SubsonicReplayGain?
    let path: String?

    func toSong() -> Song {
        Song(
            id: id,
            title: title,
            album: album ?? "Unknown Album",
            albumId: albumId ?? "",
            artist: artist ?? "Unknown Artist",
            artistId: artistId ?? "",
            track: track,
            discNumber: discNumber,
            year: year,
            genre: genre,
            duration: duration ?? 0,
            bitRate: bitRate,
            contentType: contentType ?? "audio/mpeg",
            suffix: suffix ?? "mp3",
            coverArt: coverArt,
            starred: starred,
            rating: userRating,
            replayGain: replayGain?.toReplayGain(),
            path: path
        )
    }
}

struct SubsonicReplayGain: Decodable {
    let trackGain: Float?
    let albumGain: Float?
    let trackPeak: Float?
    let albumPeak: Float?

    func toReplayGain() -> ReplayGain {
        ReplayGain(
            trackGain: trackGain,
            albumGain: albumGain,
            trackPeak: trackPeak,
            albumPeak: albumPeak
        )
    }
}

struct PlaylistsResponse: SubsonicContent, Decodable {
    static let contentKey = "playlists"
    let playlist: [SubsonicPlaylist]?
}

struct SubsonicPlaylist: Decodable {
    let id: String
    let name: String
    let comment: String?
    let owner: String?
    let songCount: Int?
    let duration: Int?
    let created: Date?
    let changed: Date?
    let coverArt: String?
    let `public`: Bool?

    func toPlaylist() -> Playlist {
        Playlist(
            id: id,
            name: name,
            comment: comment,
            owner: owner ?? "unknown",
            songCount: songCount ?? 0,
            duration: duration ?? 0,
            created: created ?? Date(),
            changed: changed ?? Date(),
            coverArt: coverArt,
            isPublic: `public` ?? false
        )
    }
}

struct PlaylistResponse: SubsonicContent, Decodable {
    static let contentKey = "playlist"
    let id: String
    let name: String
    let comment: String?
    let owner: String?
    let songCount: Int?
    let duration: Int?
    let created: Date?
    let changed: Date?
    let coverArt: String?
    let `public`: Bool?
    let entry: [SubsonicSong]?
}

struct SearchResult3Response: SubsonicContent, Decodable {
    static let contentKey = "searchResult3"
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
}

struct GenresResponse: SubsonicContent, Decodable {
    static let contentKey = "genres"
    let genre: [SubsonicGenre]?
}

struct SubsonicGenre: Decodable {
    let value: String
    let songCount: Int?
    let albumCount: Int?

    enum CodingKeys: String, CodingKey {
        case value = "value"
        case songCount, albumCount
    }

    func toGenre() -> Genre {
        Genre(
            name: value,
            songCount: songCount ?? 0,
            albumCount: albumCount ?? 0
        )
    }
}

struct LyricsResponse: SubsonicContent, Decodable {
    static let contentKey = "lyrics"
    let artist: String?
    let title: String?
    let value: String?
}

struct PingResponseContent: SubsonicContent, Decodable {
    static let contentKey = ""
    // Ping response has no content, we use header fields
}

struct SimilarSongsResponse: SubsonicContent, Decodable {
    static let contentKey = "similarSongs"
    let song: [SubsonicSong]?
}

struct RandomSongsResponse: SubsonicContent, Decodable {
    static let contentKey = "randomSongs"
    let song: [SubsonicSong]?
}

struct InternetRadioStationsResponse: SubsonicContent, Decodable {
    static let contentKey = "internetRadioStations"
    let internetRadioStation: [SubsonicInternetRadioStation]?
}

struct SubsonicInternetRadioStation: Decodable {
    let id: String
    let name: String
    let streamUrl: String
    let homePageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, streamUrl, homePageUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.id],
                    debugDescription: "Expected String or Int for internet radio station id"
                )
            )
        }

        name = try container.decode(String.self, forKey: .name)
        streamUrl = try container.decode(String.self, forKey: .streamUrl)
        homePageUrl = try container.decodeIfPresent(String.self, forKey: .homePageUrl)
    }

    func toInternetRadioStation() -> InternetRadioStation? {
        guard let streamUrl = URL(string: streamUrl),
              let scheme = streamUrl.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let cleanedHomePage = homePageUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return InternetRadioStation(
            id: id,
            name: name,
            streamUrl: streamUrl,
            homePageUrl: cleanedHomePage.flatMap(URL.init(string:))
        )
    }
}

struct EmptyResponse: SubsonicContent, Decodable {
    static let contentKey = ""
}

struct MusicFoldersResponse: SubsonicContent, Decodable {
    static let contentKey = "musicFolders"
    let musicFolder: [SubsonicMusicFolder]?

    enum CodingKeys: String, CodingKey {
        case musicFolder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle both single object and array (Subsonic API quirk)
        if let array = try? container.decode([SubsonicMusicFolder].self, forKey: .musicFolder) {
            musicFolder = array
        } else if let single = try? container.decode(SubsonicMusicFolder.self, forKey: .musicFolder) {
            musicFolder = [single]
        } else {
            musicFolder = nil
        }
    }
}

// MARK: - Indexes Response (for getIndexes endpoint)

struct IndexesResponse: SubsonicContent, Decodable {
    static let contentKey = "indexes"
    let lastModified: Int?
    let ignoredArticles: String?
    let index: [SubsonicIndex]?
    let child: [SubsonicDirectoryChild]?

    func toMusicDirectory(folderName: String) -> MusicDirectory {
        var children: [DirectoryChild] = []

        // Filesystem children first (actual subdirectories/files at root level)
        for item in child ?? [] {
            children.append(item.toDirectoryChild())
        }

        // Then artist index entries (only if no filesystem children, to avoid duplication)
        if children.isEmpty {
            for idx in index ?? [] {
                for artist in idx.artist ?? [] {
                    children.append(.folder(MusicFolder(id: artist.id, name: artist.name)))
                }
            }
        }

        return MusicDirectory(id: "root", name: folderName, parent: nil, children: children)
    }
}

struct SubsonicIndex: Decodable {
    let name: String
    let artist: [SubsonicIndexArtist]?
}

struct SubsonicIndexArtist: Decodable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
}

struct SubsonicMusicFolder: Decodable {
    let id: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle both numeric and string IDs (Navidrome returns numeric)
        if let stringId = try? container.decode(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decode(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            throw DecodingError.typeMismatch(String.self, DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.id],
                debugDescription: "Expected String or Int for id"
            ))
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func toMusicFolder() -> MusicFolder {
        MusicFolder(id: id, name: name ?? "Unknown")
    }
}

struct MusicDirectoryResponse: SubsonicContent, Decodable {
    static let contentKey = "directory"
    let id: String
    let name: String
    let parent: String?
    let child: [SubsonicDirectoryChild]?

    func toMusicDirectory() -> MusicDirectory {
        let children: [DirectoryChild] = (child ?? []).map { $0.toDirectoryChild() }
        return MusicDirectory(id: id, name: name, parent: parent, children: children)
    }
}

struct SubsonicDirectoryChild: Decodable {
    let id: String
    let title: String?
    let name: String?
    let isDir: Bool
    let parent: String?
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let duration: Int?
    let bitRate: Int?
    let contentType: String?
    let suffix: String?
    let coverArt: String?
    let starred: Date?
    let userRating: Int?
    let replayGain: SubsonicReplayGain?

    func toDirectoryChild() -> DirectoryChild {
        if isDir {
            return .folder(MusicFolder(id: id, name: title ?? name ?? "Unknown"))
        } else {
            let song = Song(
                id: id,
                title: title ?? name ?? "Unknown",
                album: album ?? "Unknown Album",
                albumId: albumId ?? "",
                artist: artist ?? "Unknown Artist",
                artistId: artistId ?? "",
                track: track,
                discNumber: discNumber,
                year: year,
                genre: genre,
                duration: duration ?? 0,
                bitRate: bitRate,
                contentType: contentType ?? "audio/mpeg",
                suffix: suffix ?? "mp3",
                coverArt: coverArt,
                starred: starred,
                rating: userRating,
                replayGain: replayGain?.toReplayGain()
            )
            return .song(song)
        }
    }
}

// MARK: - Star Type

enum StarType: Sendable {
    case song
    case album
    case artist
}

// MARK: - Artist Detail

struct ArtistDetail: Sendable {
    let id: String
    let name: String
    let albumCount: Int
    let coverArt: String?
    let starred: Date?
    let albums: [Album]
}

// MARK: - Ping Response

struct PingResponse: Sendable {
    let serverName: String
    let version: String
    let type: String
}

// MARK: - Search Results

struct SearchResults: Sendable {
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]

    var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && songs.isEmpty
    }
}

// MARK: - Starred2 Response

struct Starred2Response: SubsonicContent, Decodable {
    static let contentKey = "starred2"
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicSong]?
}

struct StarredContent: Sendable {
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]
}

// MARK: - Songs By Genre Response

struct SongsByGenreResponse: SubsonicContent, Decodable {
    static let contentKey = "songsByGenre"
    let song: [SubsonicSong]?
}

// MARK: - Single Song Response

struct SongResponse: SubsonicContent, Decodable {
    static let contentKey = "song"
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let duration: Int?
    let bitRate: Int?
    let contentType: String?
    let suffix: String?
    let coverArt: String?
    let starred: Date?
    let userRating: Int?
    let replayGain: SubsonicReplayGain?
    let path: String?

    func toSong() -> Song {
        Song(
            id: id,
            title: title,
            album: album ?? "Unknown Album",
            albumId: albumId ?? "",
            artist: artist ?? "Unknown Artist",
            artistId: artistId ?? "",
            track: track,
            discNumber: discNumber,
            year: year,
            genre: genre,
            duration: duration ?? 0,
            bitRate: bitRate,
            contentType: contentType ?? "audio/mpeg",
            suffix: suffix ?? "mp3",
            coverArt: coverArt,
            starred: starred,
            rating: userRating,
            replayGain: replayGain?.toReplayGain(),
            path: path
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
