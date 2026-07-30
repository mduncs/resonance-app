import Foundation

// MARK: - Subsonic Endpoints

enum SubsonicEndpoint {
    // System
    case ping
    case getLicense

    // Browsing
    case getMusicFolders
    case getIndexes(musicFolderId: String?)
    case getMusicDirectory(id: String)
    case getGenres
    case getArtists(musicFolderId: String?)
    case getArtist(id: String)
    case getAlbum(id: String)
    case getSong(id: String)

    // Album/Song Lists
    case getAlbumList2(type: AlbumListType, size: Int, offset: Int, musicFolderId: String?)
    case getRandomSongs(size: Int, genre: String?, musicFolderId: String?)
    case getSongsByGenre(genre: String, count: Int, offset: Int)
    case getStarred2(musicFolderId: String?)
    case getNowPlaying

    // Searching
    case search3(query: String, artistCount: Int, artistOffset: Int, albumCount: Int, albumOffset: Int, songCount: Int, songOffset: Int)

    // Playlists
    case getPlaylists(username: String?)
    case getPlaylist(id: String)
    case createPlaylist(name: String, songIds: [String])
    case updatePlaylist(id: String, name: String?, comment: String?, songIdsToAdd: [String], songIndexesToRemove: [Int])
    case deletePlaylist(id: String)

    // Media Retrieval
    case stream(id: String, maxBitRate: Int? = nil, format: String? = nil)
    case download(id: String)
    case getCoverArt(id: String, size: Int?)
    case getLyrics(artist: String?, title: String?)

    // Media Annotation
    case star(id: String?, albumId: String?, artistId: String?)
    case unstar(id: String?, albumId: String?, artistId: String?)
    case setRating(id: String, rating: Int)
    case scrobble(id: String, time: Date?, submission: Bool)

    // Bookmarks
    case getBookmarks
    case createBookmark(id: String, position: Int, comment: String?)
    case deleteBookmark(id: String)
    case getPlayQueue
    case savePlayQueue(ids: [String], current: String?, position: Int?)

    // Internet Radio
    case getInternetRadioStations

    // Library Scanning
    case getScanStatus
    case startScan

    // Similar Songs
    case getSimilarSongs(id: String, count: Int)

    var path: String {
        switch self {
        case .ping: return "ping"
        case .getLicense: return "getLicense"
        case .getMusicFolders: return "getMusicFolders"
        case .getIndexes: return "getIndexes"
        case .getMusicDirectory: return "getMusicDirectory"
        case .getGenres: return "getGenres"
        case .getArtists: return "getArtists"
        case .getArtist: return "getArtist"
        case .getAlbum: return "getAlbum"
        case .getSong: return "getSong"
        case .getAlbumList2: return "getAlbumList2"
        case .getRandomSongs: return "getRandomSongs"
        case .getSongsByGenre: return "getSongsByGenre"
        case .getStarred2: return "getStarred2"
        case .getNowPlaying: return "getNowPlaying"
        case .search3: return "search3"
        case .getPlaylists: return "getPlaylists"
        case .getPlaylist: return "getPlaylist"
        case .createPlaylist: return "createPlaylist"
        case .updatePlaylist: return "updatePlaylist"
        case .deletePlaylist: return "deletePlaylist"
        case .stream: return "stream"
        case .download: return "download"
        case .getCoverArt: return "getCoverArt"
        case .getLyrics: return "getLyrics"
        case .star: return "star"
        case .unstar: return "unstar"
        case .setRating: return "setRating"
        case .scrobble: return "scrobble"
        case .getBookmarks: return "getBookmarks"
        case .createBookmark: return "createBookmark"
        case .deleteBookmark: return "deleteBookmark"
        case .getPlayQueue: return "getPlayQueue"
        case .savePlayQueue: return "savePlayQueue"
        case .getInternetRadioStations: return "getInternetRadioStations"
        case .getScanStatus: return "getScanStatus"
        case .startScan: return "startScan"
        case .getSimilarSongs: return "getSimilarSongs"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case .ping, .getLicense, .getMusicFolders, .getGenres, .getNowPlaying,
             .getBookmarks, .getPlayQueue, .getInternetRadioStations, .getScanStatus, .startScan:
            return []

        case .getIndexes(let musicFolderId):
            return musicFolderId.map { [URLQueryItem(name: "musicFolderId", value: $0)] } ?? []

        case .getMusicDirectory(let id), .getArtist(let id), .getAlbum(let id), .getSong(let id),
             .getPlaylist(let id), .deletePlaylist(let id), .download(let id), .deleteBookmark(let id):
            return [URLQueryItem(name: "id", value: id)]

        case .getArtists(let musicFolderId):
            return musicFolderId.map { [URLQueryItem(name: "musicFolderId", value: $0)] } ?? []

        case .getAlbumList2(let type, let size, let offset, let musicFolderId):
            var items = [
                URLQueryItem(name: "type", value: type.rawValue),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            if let folderId = musicFolderId {
                items.append(URLQueryItem(name: "musicFolderId", value: folderId))
            }
            return items

        case .getRandomSongs(let size, let genre, let musicFolderId):
            var items = [URLQueryItem(name: "size", value: String(size))]
            if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
            if let folderId = musicFolderId { items.append(URLQueryItem(name: "musicFolderId", value: folderId)) }
            return items

        case .getSongsByGenre(let genre, let count, let offset):
            return [
                URLQueryItem(name: "genre", value: genre),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "offset", value: String(offset))
            ]

        case .getStarred2(let musicFolderId):
            return musicFolderId.map { [URLQueryItem(name: "musicFolderId", value: $0)] } ?? []

        case .search3(let query, let artistCount, let artistOffset, let albumCount, let albumOffset, let songCount, let songOffset):
            return [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "artistCount", value: String(artistCount)),
                URLQueryItem(name: "artistOffset", value: String(artistOffset)),
                URLQueryItem(name: "albumCount", value: String(albumCount)),
                URLQueryItem(name: "albumOffset", value: String(albumOffset)),
                URLQueryItem(name: "songCount", value: String(songCount)),
                URLQueryItem(name: "songOffset", value: String(songOffset))
            ]

        case .getPlaylists(let username):
            return username.map { [URLQueryItem(name: "username", value: $0)] } ?? []

        case .createPlaylist(let name, let songIds):
            var items = [URLQueryItem(name: "name", value: name)]
            items.append(contentsOf: songIds.map { URLQueryItem(name: "songId", value: $0) })
            return items

        case .updatePlaylist(let id, let name, let comment, let songIdsToAdd, let songIndexesToRemove):
            var items = [URLQueryItem(name: "playlistId", value: id)]
            if let name { items.append(URLQueryItem(name: "name", value: name)) }
            if let comment { items.append(URLQueryItem(name: "comment", value: comment)) }
            items.append(contentsOf: songIdsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) })
            items.append(contentsOf: songIndexesToRemove.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) })
            return items

        case .stream(let id, let maxBitRate, let format):
            var items = [URLQueryItem(name: "id", value: id)]
            if let maxBitRate { items.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate))) }
            if let format { items.append(URLQueryItem(name: "format", value: format)) }
            return items

        case .getCoverArt(let id, let size):
            var items = [URLQueryItem(name: "id", value: id)]
            if let size { items.append(URLQueryItem(name: "size", value: String(size))) }
            return items

        case .getLyrics(let artist, let title):
            var items: [URLQueryItem] = []
            if let artist { items.append(URLQueryItem(name: "artist", value: artist)) }
            if let title { items.append(URLQueryItem(name: "title", value: title)) }
            return items

        case .star(let id, let albumId, let artistId):
            var items: [URLQueryItem] = []
            if let id { items.append(URLQueryItem(name: "id", value: id)) }
            if let albumId { items.append(URLQueryItem(name: "albumId", value: albumId)) }
            if let artistId { items.append(URLQueryItem(name: "artistId", value: artistId)) }
            return items

        case .unstar(let id, let albumId, let artistId):
            var items: [URLQueryItem] = []
            if let id { items.append(URLQueryItem(name: "id", value: id)) }
            if let albumId { items.append(URLQueryItem(name: "albumId", value: albumId)) }
            if let artistId { items.append(URLQueryItem(name: "artistId", value: artistId)) }
            return items

        case .setRating(let id, let rating):
            return [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "rating", value: String(rating))
            ]

        case .scrobble(let id, let time, let submission):
            var items = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "submission", value: submission ? "true" : "false")
            ]
            if let time {
                items.append(URLQueryItem(name: "time", value: String(Int(time.timeIntervalSince1970 * 1000))))
            }
            return items

        case .createBookmark(let id, let position, let comment):
            var items = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "position", value: String(position))
            ]
            if let comment { items.append(URLQueryItem(name: "comment", value: comment)) }
            return items

        case .savePlayQueue(let ids, let current, let position):
            var items = ids.map { URLQueryItem(name: "id", value: $0) }
            if let current { items.append(URLQueryItem(name: "current", value: current)) }
            if let position { items.append(URLQueryItem(name: "position", value: String(position))) }
            return items

        case .getSimilarSongs(let id, let count):
            return [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "count", value: String(count))
            ]
        }
    }
}

enum AlbumListType: String, Sendable {
    case random
    case newest
    case highest
    case frequent
    case recent
    case alphabeticalByName
    case alphabeticalByArtist
    case starred
    case byYear
    case byGenre
}
