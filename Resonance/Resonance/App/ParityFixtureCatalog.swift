import CoreGraphics
import Foundation
import ImageIO

// MARK: - Fixture route and state vocabulary

/// Stable, launch-selectable routes for the parity atlas.
///
/// These values are deliberately independent of SwiftUI's `SidebarItem` enum.
/// The atlas is a test and capture seam, so its public vocabulary should not
/// change when a production navigation enum is reorganized.
enum ParityFixtureRoute: String, CaseIterable, Codable, Sendable, Hashable {
    case shell = "shell"
    case home = "home"
    case recentlyAdded = "recently-added"
    case recentlyPlayed = "recently-played"
    case albums = "albums"
    case albumDetail = "album-detail"
    case artists = "artists"
    case artistDetail = "artist-detail"
    case songs = "songs"
    case genres = "genres"
    case genreDetail = "genre-detail"
    case playlists = "playlists"
    case playlistDetail = "playlist-detail"
    case smartPlaylist = "smart-playlist"
    case likedSongs = "liked-songs"
    case search = "search"
    case searchResults = "search-results"
    case searchNoResults = "search-no-results"
    case queue = "queue"
    case lyrics = "lyrics"
    case footer = "footer"
    case miniPlayerArtwork = "mini-player-artwork"
    case miniPlayerQueue = "mini-player-queue"
    case miniPlayerLyrics = "mini-player-lyrics"
    case fullscreenNowPlaying = "fullscreen-now-playing"

    /// Accept a few human-friendly spellings without changing the stable raw
    /// values written into capture manifests.
    static func parse(_ rawValue: String?) -> Self? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if let route = Self(rawValue: normalized) {
            return route
        }

        switch normalized {
        case "main-shell", "sidebar": return .shell
        case "recent-added": return .recentlyAdded
        case "recent-played": return .recentlyPlayed
        case "album": return .albumDetail
        case "artist": return .artistDetail
        case "playlist": return .playlistDetail
        case "smart-playlists": return .smartPlaylist
        case "liked", "favorites": return .likedSongs
        case "search-populated", "search-populated-results": return .searchResults
        case "search-empty", "search-no-result", "search-no-results": return .searchNoResults
        case "playing-next", "history": return .queue
        case "mini-player-art", "miniplayer-art", "miniplayer-artwork": return .miniPlayerArtwork
        case "mini-player-queue", "miniplayer-queue": return .miniPlayerQueue
        case "mini-player-lyrics", "miniplayer-lyrics": return .miniPlayerLyrics
        case "fullscreen", "now-playing-fullscreen", "full-screen-now-playing": return .fullscreenNowPlaying
        case "now-playing", "now-playing-footer": return .footer
        default: return nil
        }
    }
}

/// State vocabulary shared by route selection and fixture lyrics rendering.
enum ParityFixtureState: String, CaseIterable, Codable, Sendable, Hashable {
    case loaded
    case empty
    case loading
    case error
    case selected
    case playing
    case paused
    case synced
    case plain
    case noLyrics = "no-lyrics"

    static func parse(_ rawValue: String?) -> Self? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if let state = Self(rawValue: normalized) {
            return state
        }

        switch normalized {
        case "ready", "populated": return .loaded
        case "none", "not-found", "nolyrics": return .noLyrics
        case "synchronised", "synchronized": return .synced
        case "unsynced", "plain-text", "plainlyrics": return .plain
        default: return nil
        }
    }
}

struct ParityFixtureRouteManifestEntry: Identifiable, Codable, Sendable, Equatable {
    let route: ParityFixtureRoute
    let productionSurface: String
    let states: [ParityFixtureState]

    var id: String { route.rawValue }
}

// MARK: - Deterministic fixture value types

struct ParityFixturePlayHistoryEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: String
    let songID: String
    let playedAt: Date
    let durationPlayed: Int
}

/// A complete, sanitized local library used by parity captures and tests.
///
/// The catalog is value-typed and `Sendable`: service actors receive a frozen
/// snapshot, and fixture launch cannot accidentally share mutable production
/// state. All IDs, dates, ordering, and artwork bytes are deterministic.
struct ParityFixtureCatalog: Sendable {
    /// UUID-shaped so AppState can expose an in-memory synthetic `Server`
    /// without introducing a second identity for database joins.
    static let serverID = "00000000-0000-4000-8000-000000000001"
    static let serverName = "Parity Atlas Library"
    static let baseDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

    let serverId: String
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]
    let genres: [Genre]
    let playlists: [Playlist]
    let smartPlaylists: [SmartPlaylist]
    let musicFolders: [MusicFolder]
    let directories: [String: MusicDirectory]
    let queue: [QueueItem]
    let queueHistory: [QueueItem]
    let recentlyAdded: [Album]
    let recentlyPlayed: [Song]
    let playHistory: [ParityFixturePlayHistoryEntry]
    let likedSongIDs: Set<String>
    let likedAlbumIDs: Set<String>
    let likedArtistIDs: Set<String>
    let starredSongIDs: Set<String>
    let starredAlbumIDs: Set<String>
    let starredArtistIDs: Set<String>
    let searchResultsByQuery: [String: SearchResults]
    let lyricsBySongID: [String: CachedLyrics]
    let smartPlaylistSongIDsByID: [String: [String]]
    let playlistSongIDsByID: [String: [String]]
    let artworkDataByID: [String: Data]

    var history: [QueueItem] { queueHistory }

    /// Route manifest is kept beside the catalog so a capture runner can
    /// enumerate exactly what this fixture claims to support.
    static let routeManifest: [ParityFixtureRouteManifestEntry] = [
        .init(route: .shell, productionSurface: "ContentView + SidebarView", states: [.loaded]),
        .init(route: .home, productionSurface: "HomeView", states: [.loaded]),
        .init(route: .recentlyAdded, productionSurface: "RecentlyAddedView", states: [.loaded]),
        .init(route: .recentlyPlayed, productionSurface: "RecentlyPlayedView", states: [.loaded]),
        .init(route: .albums, productionSurface: "AlbumsView", states: [.loaded]),
        .init(route: .albumDetail, productionSurface: "AlbumDetailView", states: [.loaded]),
        .init(route: .artists, productionSurface: "ArtistsView", states: [.loaded]),
        .init(route: .artistDetail, productionSurface: "Artist detail", states: [.loaded]),
        .init(route: .songs, productionSurface: "SongsView", states: [.loaded]),
        .init(route: .genres, productionSurface: "GenresView", states: [.loaded]),
        .init(route: .genreDetail, productionSurface: "GenreDetailView", states: [.loaded]),
        .init(route: .playlists, productionSurface: "PlaylistsView", states: [.loaded]),
        .init(route: .playlistDetail, productionSurface: "PlaylistDetailView", states: [.loaded]),
        .init(route: .smartPlaylist, productionSurface: "SmartPlaylistDetailView", states: [.loaded]),
        .init(route: .likedSongs, productionSurface: "LikedSongsView", states: [.loaded]),
        .init(route: .search, productionSurface: "SearchView", states: [.empty]),
        .init(route: .searchResults, productionSurface: "SearchView results", states: [.loaded]),
        .init(route: .searchNoResults, productionSurface: "SearchView no results", states: [.empty]),
        .init(route: .queue, productionSurface: "QueueView / Playing Next / History", states: [.loaded, .empty]),
        .init(route: .lyrics, productionSurface: "LyricsView", states: [.synced, .plain, .noLyrics, .loading, .error]),
        .init(route: .footer, productionSurface: "NowPlayingBar", states: [.paused, .playing]),
        .init(route: .miniPlayerArtwork, productionSurface: "MiniPlayerView artwork", states: [.paused, .playing]),
        .init(route: .miniPlayerQueue, productionSurface: "MiniPlayerView queue", states: [.paused, .playing]),
        .init(route: .miniPlayerLyrics, productionSurface: "MiniPlayerView lyrics", states: [.synced, .plain, .noLyrics, .loading, .error]),
        .init(route: .fullscreenNowPlaying, productionSurface: "ImmersiveView", states: [.paused, .playing])
    ]

    /// Compatibility spelling for callers that prefer `serverID`.
    var serverID: String { serverId }

    var artistByID: [String: Artist] { Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) }) }
    var albumByID: [String: Album] { Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) }) }
    var songByID: [String: Song] { Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }) }
    var playlistByID: [String: Playlist] { Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) }) }
    var smartPlaylistByID: [String: SmartPlaylist] {
        Dictionary(uniqueKeysWithValues: smartPlaylists.map { ($0.id, $0) })
    }

    var albumsByArtistID: [String: [Album]] {
        Dictionary(grouping: albums, by: \.artistId)
    }

    var songsByAlbumID: [String: [Song]] {
        Dictionary(grouping: songs, by: \.albumId)
    }

    var songsByArtistID: [String: [Song]] {
        Dictionary(grouping: songs, by: \.artistId)
    }

    var songsByGenre: [String: [Song]] {
        Dictionary(grouping: songs.compactMap { song in
            song.genre.map { (genre: $0, song: song) }
        }, by: \.genre)
        .mapValues { $0.map(\.song) }
    }

    var artworkIDs: Set<String> { Set(artworkDataByID.keys) }

    var searchNoResultQuery: String { "zzzz-no-match" }
    var searchNoResults: SearchResults {
        searchResultsByQuery[searchNoResultQuery] ?? SearchResults(artists: [], albums: [], songs: [])
    }

    var searchResults: SearchResults {
        searchResultsByQuery["neon"] ?? SearchResults(artists: [], albums: [], songs: [])
    }

    /// Returns a deterministic PNG for a known art ID. Unknown IDs are also
    /// generated locally, which prevents an accidental URLSession fallback.
    func artworkPNGData(for artworkID: String, size: Int = 320) -> Data? {
        guard !artworkID.isEmpty else { return nil }
        if size == 320, let data = artworkDataByID[artworkID] {
            return data
        }
        return Self.makeArtworkPNG(seed: artworkID, size: max(32, min(size, 1024)))
    }

    var artworkByID: [String: Data] { artworkDataByID }

    func artworkData(for artworkID: String, size: Int = 320) -> Data? {
        artworkPNGData(for: artworkID, size: size)
    }

    func lyrics(for songID: String) -> CachedLyrics? {
        lyricsBySongID[songID]
    }

    /// Convenience aliases make the catalog pleasant to consume from tests
    /// and from launch wiring without forcing callers to know storage names.
    var artistsByID: [String: Artist] { artistByID }
    var albumsByID: [String: Album] { albumByID }
    var songsByID: [String: Song] { songByID }
    var playlistsByID: [String: Playlist] { playlistByID }

    init(
        serverId: String = Self.serverID,
        artists: [Artist],
        albums: [Album],
        songs: [Song],
        genres: [Genre],
        playlists: [Playlist],
        smartPlaylists: [SmartPlaylist] = [],
        musicFolders: [MusicFolder] = [],
        directories: [String: MusicDirectory] = [:],
        queue: [QueueItem] = [],
        queueHistory: [QueueItem] = [],
        recentlyAdded: [Album] = [],
        recentlyPlayed: [Song] = [],
        playHistory: [ParityFixturePlayHistoryEntry] = [],
        likedSongIDs: Set<String> = [],
        likedAlbumIDs: Set<String> = [],
        likedArtistIDs: Set<String> = [],
        starredSongIDs: Set<String> = [],
        starredAlbumIDs: Set<String> = [],
        starredArtistIDs: Set<String> = [],
        searchResultsByQuery: [String: SearchResults] = [:],
        lyricsBySongID: [String: CachedLyrics] = [:],
        smartPlaylistSongIDsByID: [String: [String]] = [:],
        playlistSongIDsByID: [String: [String]] = [:],
        artworkDataByID: [String: Data] = [:]
    ) {
        self.serverId = serverId
        self.artists = artists
        self.albums = albums
        self.songs = songs
        self.genres = genres
        self.playlists = playlists
        self.smartPlaylists = smartPlaylists
        self.musicFolders = musicFolders
        self.directories = directories
        self.queue = queue
        self.queueHistory = queueHistory
        self.recentlyAdded = recentlyAdded
        self.recentlyPlayed = recentlyPlayed
        self.playHistory = playHistory
        self.likedSongIDs = likedSongIDs
        self.likedAlbumIDs = likedAlbumIDs
        self.likedArtistIDs = likedArtistIDs
        self.starredSongIDs = starredSongIDs
        self.starredAlbumIDs = starredAlbumIDs
        self.starredArtistIDs = starredArtistIDs
        self.searchResultsByQuery = searchResultsByQuery
        self.lyricsBySongID = lyricsBySongID
        self.smartPlaylistSongIDsByID = smartPlaylistSongIDsByID
        self.playlistSongIDsByID = playlistSongIDsByID

        let artworkIDs = Set(
            albums.compactMap(\.coverArt)
                + artists.compactMap(\.coverArt)
                + songs.compactMap(\.coverArt)
                + playlists.compactMap(\.coverArt)
        )
        if artworkDataByID.isEmpty {
            self.artworkDataByID = Dictionary(uniqueKeysWithValues: artworkIDs.sorted().compactMap { id in
                Self.makeArtworkPNG(seed: id, size: 320).map { (id, $0) }
            })
        } else {
            var resolved = artworkDataByID
            for id in artworkIDs where resolved[id] == nil {
                resolved[id] = Self.makeArtworkPNG(seed: id, size: 320)
            }
            self.artworkDataByID = resolved
        }
    }

    // MARK: Standard atlas

    static let standard: ParityFixtureCatalog = makeStandard()
    static let atlas: ParityFixtureCatalog = standard
    static let `default`: ParityFixtureCatalog = standard

    /// Opt-in synthetic scale, never selected by a normal app launch. The
    /// fixture itself retains all metadata, so its RSS is not a production
    /// memory benchmark; it verifies bounded UI reads and interactions.
    static let scale: ParityFixtureCatalog = makeScale()

    private static func makeScale() -> ParityFixtureCatalog {
        let base = standard
        let extraArtistCount = 15_000 - base.artists.count
        let extraAlbumCount = 32_000 - base.albums.count
        let extraSongCount = 100_000 - base.songs.count
        var artists = base.artists
        var albums = base.albums
        var songs = base.songs
        artists.reserveCapacity(15_000)
        albums.reserveCapacity(32_000)
        songs.reserveCapacity(100_000)
        for index in 0..<extraArtistCount {
            let albumCount = extraAlbumCount / extraArtistCount
                + (index < extraAlbumCount % extraArtistCount ? 1 : 0)
            artists.append(Artist(
                id: "scale-artist-\(index)", name: String(format: "Scale Artist %05d", index),
                albumCount: albumCount, coverArt: nil, starred: nil
            ))
        }
        for index in 0..<extraAlbumCount {
            let artist = artists[base.artists.count + index % extraArtistCount]
            let songCount = extraSongCount / extraAlbumCount
                + (index < extraSongCount % extraAlbumCount ? 1 : 0)
            let album = Album(
                id: "scale-album-\(index)", name: String(format: "Scale Album %05d", index),
                artist: artist.name, artistId: artist.id, songCount: songCount,
                duration: songCount * 240, year: 1980 + index % 47, genre: "Electronic",
                coverArt: "atlas-art-01", starred: nil, rating: nil,
                addedAt: baseDate.addingTimeInterval(-Double(index) * 60)
            )
            albums.append(album)
            for track in 1...songCount {
                let ordinal = songs.count
                songs.append(Song(
                    id: "scale-song-\(ordinal)", title: String(format: "Scale Song %06d", ordinal),
                    album: album.name, albumId: album.id, artist: artist.name, artistId: artist.id,
                    track: track, discNumber: 1, year: album.year, genre: album.genre,
                    duration: 240, bitRate: 320, contentType: "audio/mpeg", suffix: "mp3",
                    coverArt: album.coverArt, starred: nil, rating: nil, replayGain: nil,
                    playCount: ordinal % 101, addedAt: album.addedAt
                ))
            }
        }

        // The usual playlist-detail route targets the third playlist. Retain
        // its ID, but make its scale-only contents 25k distinct songs repeated
        // twice: row identity must represent occurrences, not unique song IDs.
        var playlists = base.playlists
        let original = playlists[2]
        let occurrences = (0..<50_000).map { songs[($0 / 2) * 3] }
        playlists[2] = Playlist(
            id: original.id, name: "Scale Playlist — 50,000 Entries",
            comment: "Synthetic scale fixture with repeated song occurrences.",
            owner: original.owner, songCount: occurrences.count,
            duration: occurrences.reduce(0) { $0 + $1.duration },
            created: original.created, changed: original.changed,
            coverArt: original.coverArt, isPublic: original.isPublic
        )
        var playlistIDs = base.playlistSongIDsByID
        playlistIDs[original.id] = occurrences.map(\.id)
        let songGenres = Dictionary(grouping: songs, by: { $0.genre ?? "" })
        let albumGenres = Dictionary(grouping: albums, by: { $0.genre ?? "" })
        let genres = base.genres.map {
            Genre(name: $0.name, songCount: songGenres[$0.name]?.count ?? 0,
                  albumCount: albumGenres[$0.name]?.count ?? 0)
        }
        return ParityFixtureCatalog(
            artists: artists, albums: albums, songs: songs, genres: genres,
            playlists: playlists, smartPlaylists: base.smartPlaylists,
            musicFolders: base.musicFolders, directories: base.directories,
            queue: base.queue, queueHistory: base.queueHistory,
            recentlyAdded: base.recentlyAdded, recentlyPlayed: base.recentlyPlayed,
            playHistory: base.playHistory, likedSongIDs: base.likedSongIDs,
            likedAlbumIDs: base.likedAlbumIDs, likedArtistIDs: base.likedArtistIDs,
            starredSongIDs: base.starredSongIDs, starredAlbumIDs: base.starredAlbumIDs,
            starredArtistIDs: base.starredArtistIDs,
            searchResultsByQuery: base.searchResultsByQuery,
            lyricsBySongID: base.lyricsBySongID,
            smartPlaylistSongIDsByID: base.smartPlaylistSongIDsByID,
            playlistSongIDsByID: playlistIDs, artworkDataByID: base.artworkDataByID
        )
    }

    static func makeStandard() -> ParityFixtureCatalog {
        let artistSpecs: [(id: String, name: String, starred: Bool)] = [
            ("atlas-artist-01", "Neon Cartography", true),
            ("atlas-artist-02", "The Weather Bureau", false),
            ("atlas-artist-03", "Mara Vellum Ensemble", true),
            ("atlas-artist-04", "Southbound Arithmetic", false),
            ("atlas-artist-05", "Juniper & Static", false)
        ]

        struct AlbumSpec {
            let id: String
            let name: String
            let artistIndex: Int
            let genre: String
            let year: Int
            let coverArt: String?
            let titles: [String]
        }

        let albumSpecs: [AlbumSpec] = [
            .init(id: "atlas-album-01", name: "Meridian Bloom", artistIndex: 0, genre: "Electronic", year: 2026, coverArt: "atlas-art-01", titles: ["Aerial Lines", "Meridian Bloom", "Afterimage Protocol"]),
            .init(id: "atlas-album-02", name: "Glass Transit", artistIndex: 0, genre: "Ambient", year: 2024, coverArt: "atlas-art-02", titles: ["Platform 7", "Glass Transit", "Window Seat, 04:17"]),
            .init(id: "atlas-album-03", name: "Copper Weather", artistIndex: 1, genre: "Indie Rock", year: 2023, coverArt: "atlas-art-03", titles: ["Forecast: Copper", "Small Machines", "The Long Way Home"]),
            .init(id: "atlas-album-04", name: "The Atlas of Rooms That No Longer Exist", artistIndex: 1, genre: "Post-Rock", year: 2022, coverArt: nil, titles: ["Index of Unfinished Doors", "A Room With a Very Long Name for Truncation", "Blueprints in Rain"]),
            .init(id: "atlas-album-05", name: "Archive of Small Hours", artistIndex: 2, genre: "Classical", year: 2021, coverArt: "atlas-art-04", titles: ["I. Lumen", "II. Coda for Empty Streets", "III. Marginalia", "IV. Night Study"]),
            .init(id: "atlas-album-06", name: "Static Orchard", artistIndex: 2, genre: "Jazz", year: 2020, coverArt: "atlas-art-05", titles: ["Static Orchard", "Blue in the Margins", "Five Uneven Windows"]),
            .init(id: "atlas-album-07", name: "Velvet Signal", artistIndex: 3, genre: "Hip-Hop", year: 2019, coverArt: "atlas-art-06", titles: ["Signal / Noise", "No Fixed Address", "Velvet Signal"]),
            .init(id: "atlas-album-08", name: "Night Library", artistIndex: 4, genre: "Folk", year: 2018, coverArt: "atlas-art-07", titles: ["Night Library", "Juniper Thread", "The Last Warm Light"])
        ]

        let artistIDs = artistSpecs.map(\.id)
        let artistNames = artistSpecs.map(\.name)
        let fixedStars = [
            (song: 0, days: 1), (song: 4, days: 3), (song: 7, days: 5),
            (song: 13, days: 8), (song: 18, days: 13), (song: 24, days: 21)
        ]
        let starDaysBySong = Dictionary(uniqueKeysWithValues: fixedStars.map { ($0.song, $0.days) })
        // Synthetic coverage, not captured Music library metadata: include zero,
        // repeated values, and unknowns for the Plays and Date Added columns.
        let playCountSamples: [Int?] = [0, 7, 7, nil, 42, 1]
        let addedDaysSamples: [Int?] = [0, 1, 1, nil, 30, 365]
        var songs: [Song] = []
        songs.reserveCapacity(albumSpecs.reduce(0) { $0 + $1.titles.count })

        // Explicitly synthetic coverage: full/partial/unknown album dates and
        // multiple/empty/unsupported grouping tags. Never native library values.
        func releaseDate(for index: Int) -> MediaReleaseDate? {
            switch index % 4 {
            case 0: return MediaReleaseDate(year: albumSpecs[index].year, month: 9, day: 10)
            case 1: return MediaReleaseDate(year: albumSpecs[index].year, month: 9)
            case 2: return MediaReleaseDate(year: albumSpecs[index].year)
            default: return nil
            }
        }
        let groupingSamples: [[String]?] = [nil, [], ["Live"], ["Soundtrack", "Archive"]]

        for (albumIndex, spec) in albumSpecs.enumerated() {
            for (titleIndex, title) in spec.titles.enumerated() {
                let ordinal = songs.count
                let duration = 178 + ((ordinal * 37) % 211)
                let isExplicit = ordinal == 6 || ordinal == 17 || ordinal == 21
                let coverArt = spec.coverArt
                songs.append(
                    Song(
                        id: String(format: "atlas-song-%02d", ordinal + 1),
                        title: title,
                        album: spec.name,
                        albumId: spec.id,
                        artist: artistNames[spec.artistIndex],
                        artistId: artistIDs[spec.artistIndex],
                        track: titleIndex + 1,
                        discNumber: albumIndex == 4 && titleIndex >= 2 ? 2 : 1,
                        year: spec.year,
                        genre: spec.genre,
                        duration: duration,
                        bitRate: ordinal % 5 == 0 ? 256 : 320,
                        contentType: "audio/mpeg",
                        suffix: "mp3",
                        coverArt: coverArt,
                        starred: starDaysBySong[ordinal].map { date(daysBefore: $0) },
                        rating: ordinal % 7 == 0 ? 5 : (ordinal % 4 == 0 ? 3 : nil),
                        replayGain: ordinal % 6 == 0 ? ReplayGain(trackGain: -7.2, albumGain: -6.4, trackPeak: 0.98, albumPeak: 0.99) : nil,
                        isExplicit: isExplicit,
                        path: "Atlas/\(artistNames[spec.artistIndex])/\(spec.name)/\(title).mp3",
                        playCount: playCountSamples[ordinal % playCountSamples.count],
                        addedAt: addedDaysSamples[ordinal % addedDaysSamples.count].map { date(daysBefore: $0) },
                        releaseDate: releaseDate(for: albumIndex),
                        groupings: groupingSamples[ordinal % groupingSamples.count]
                    )
                )
            }
        }

        let albumSongMap = Dictionary(grouping: songs, by: \.albumId)
        let albums = albumSpecs.enumerated().map { index, spec in
            let albumSongs = albumSongMap[spec.id] ?? []
            return Album(
                id: spec.id,
                name: spec.name,
                artist: artistNames[spec.artistIndex],
                artistId: artistIDs[spec.artistIndex],
                songCount: albumSongs.count,
                duration: albumSongs.reduce(0) { $0 + $1.duration },
                year: spec.year,
                genre: spec.genre,
                coverArt: spec.coverArt,
                starred: index == 0 || index == 4 ? date(daysBefore: index + 2) : nil,
                rating: index == 0 ? 5 : (index == 3 ? 2 : nil),
                // Fixed Sep19 2026 reference shared with RecentlyAdded fixture grouping.
                addedAt: [0, 1, 2, 3, 12, 60, nil, 120][index % 8].map {
                    Date(timeIntervalSince1970: 1789819200 - Double($0) * 86400)
                },
                releaseDate: releaseDate(for: index)
            )
        }

        let albumIDsByArtist = Dictionary(grouping: albums, by: \.artistId)
        let artists = artistSpecs.enumerated().map { index, spec in
            Artist(
                id: spec.id,
                name: spec.name,
                albumCount: albumIDsByArtist[spec.id]?.count ?? 0,
                coverArt: index == 1 ? nil : "atlas-art-0\(min(index + 1, 7))",
                starred: spec.starred ? date(daysBefore: index + 1) : nil
            )
        }

        let genreNames = ["Ambient", "Classical", "Electronic", "Folk", "Hip-Hop", "Indie Rock", "Jazz", "Post-Rock"]
        let genres = genreNames.map { genre in
            let genreSongs = songs.filter { $0.genre == genre }
            let genreAlbums = Set(genreSongs.map(\.albumId))
            return Genre(name: genre, songCount: genreSongs.count, albumCount: genreAlbums.count)
        }

        let playlistSpecs: [(id: String, name: String, comment: String?, indices: [Int], art: String?, public: Bool)] = [
            ("atlas-playlist-01", "Late Night Instrumentals", "A quiet route through the library.", [1, 3, 8, 12, 15, 19, 22], "atlas-art-02", false),
            ("atlas-playlist-02", "Road Test / 2026", "Loud enough for the long drive; explicit tracks are marked.", [0, 2, 5, 6, 10, 16, 20, 23], "atlas-art-03", true),
            ("atlas-playlist-03", "Small Rooms, Big Weather", "A deliberately long title that should wrap without collapsing the row.", [4, 7, 9, 7, 11, 13, 17, 18, 21, 24], nil, false),
            ("atlas-playlist-04", "Pinned for Comparison", "Fixture playlist with missing artwork.", [2, 14, 16, 20], "atlas-art-06", false)
        ]
        let playlists = playlistSpecs.enumerated().map { index, spec in
            let selected = spec.indices.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
            return Playlist(
                id: spec.id,
                name: spec.name,
                comment: spec.comment,
                owner: "atlas-user",
                songCount: selected.count,
                duration: selected.reduce(0) { $0 + $1.duration },
                created: date(daysBefore: 40 + index * 4),
                changed: date(daysBefore: 2 + index),
                coverArt: spec.art,
                isPublic: spec.public
            )
        }
        let playlistSongIDs = Dictionary(uniqueKeysWithValues: playlistSpecs.map { spec in
            (spec.id, spec.indices.compactMap { songs.indices.contains($0) ? songs[$0].id : nil })
        })

        var smartPlaylist = SmartPlaylist(
            id: "atlas-smart-01",
            name: "High Rotation · Electronic",
            serverId: Self.serverID,
            ruleGroup: SmartPlaylistRuleGroup(
                conjunction: .and,
                rules: [
                    SmartPlaylistRule(id: deterministicUUID(201), field: .genre, op: .contains, value: "Electronic"),
                    SmartPlaylistRule(id: deterministicUUID(202), field: .rating, op: .greaterOrEqual, value: "3")
                ]
            ),
            sortBy: "rating",
            sortOrder: .desc,
            itemLimit: 12
        )
        smartPlaylist.createdAt = date(daysBefore: 28)
        smartPlaylist.updatedAt = date(daysBefore: 1)
        smartPlaylist.lastEvaluated = date(daysBefore: 1)

        let smartSongIDs = songs.filter {
            $0.genre == "Electronic" && ($0.rating ?? 0) >= 3
        }.map(\.id)

        let queueSongs = [0, 1, 8, 13, 18, 24].compactMap { songs.indices.contains($0) ? songs[$0] : nil }
        let queue = queueSongs.enumerated().map { index, song in
            QueueItem(id: deterministicUUID(index + 1), song: song, playedAt: index == 0 ? date(daysBefore: 1) : nil)
        }
        let historySongs = [20, 4, 11, 17].compactMap { songs.indices.contains($0) ? songs[$0] : nil }
        let queueHistory = historySongs.enumerated().map { index, song in
            QueueItem(id: deterministicUUID(100 + index), song: song, playedAt: date(daysBefore: 3 + index))
        }

        let playHistory = [
            (0, 1, 213), (4, 2, 291), (8, 4, 198), (13, 7, 327),
            (17, 10, 184), (20, 15, 244), (24, 21, 401)
        ].compactMap { item -> ParityFixturePlayHistoryEntry? in
            guard songs.indices.contains(item.0) else { return nil }
            return ParityFixturePlayHistoryEntry(
                id: String(format: "atlas-history-%02d", item.0 + 1),
                songID: songs[item.0].id,
                playedAt: date(daysBefore: item.1),
                durationPlayed: min(item.2, songs[item.0].duration)
            )
        }

        let likedSongIDs = Set([0, 1, 4, 8, 13, 18, 24].compactMap { songs.indices.contains($0) ? songs[$0].id : nil })
        let likedAlbumIDs = Set([0, 1, 4].compactMap { albums.indices.contains($0) ? albums[$0].id : nil })
        let likedArtistIDs = Set([0, 2].compactMap { artists.indices.contains($0) ? artists[$0].id : nil })
        let starredSongIDs = Set(songs.compactMap { $0.starred == nil ? nil : $0.id })
        let starredAlbumIDs = Set(albums.compactMap { $0.starred == nil ? nil : $0.id })
        let starredArtistIDs = Set(artists.compactMap { $0.starred == nil ? nil : $0.id })

        let syncedSong = songs[0]
        let plainSong = songs[1]
        let noLyricsSong = songs[2]
        let lyrics: [String: CachedLyrics] = [
            syncedSong.id: CachedLyrics(
                songId: syncedSong.id,
                source: .navidrome,
                syncedLyrics: "[00:00.00]Aerial lines over sleeping wires\n[00:18.40]The city turns its quiet side to us\n[00:36.20]Every signal finds a home",
                plainLyrics: nil,
                fetchedAt: date(daysBefore: 2)
            ),
            plainSong.id: CachedLyrics(
                songId: plainSong.id,
                source: .lrclib,
                syncedLyrics: nil,
                plainLyrics: "Glass transit, a window in motion\nA small blue room crossing the ocean\nKeep the light on until we arrive.",
                fetchedAt: date(daysBefore: 4)
            ),
            noLyricsSong.id: CachedLyrics(
                songId: noLyricsSong.id,
                source: .notFound,
                syncedLyrics: nil,
                plainLyrics: nil,
                fetchedAt: date(daysBefore: 1)
            )
        ]

        let searchResults = makeSearchResults(
            songs: songs,
            albums: albums,
            artists: artists
        )

        let folders = [MusicFolder(id: "atlas-folder-library", name: "Atlas Library")]
        let rootDirectory = MusicDirectory(
            id: "atlas-folder-library",
            name: "Atlas Library",
            parent: nil,
            children: artists.map { .folder(MusicFolder(id: "atlas-folder-\($0.id)", name: $0.name)) }
        )
        let directories = Dictionary(uniqueKeysWithValues: [rootDirectory].map { ($0.id, $0) })

        return ParityFixtureCatalog(
            artists: artists,
            albums: albums,
            songs: songs,
            genres: genres,
            playlists: playlists,
            smartPlaylists: [smartPlaylist],
            musicFolders: folders,
            directories: directories,
            queue: queue,
            queueHistory: queueHistory,
            recentlyAdded: Array(albums.prefix(6)),
            recentlyPlayed: playHistory.compactMap { entry in songs.first { $0.id == entry.songID } },
            playHistory: playHistory,
            likedSongIDs: likedSongIDs,
            likedAlbumIDs: likedAlbumIDs,
            likedArtistIDs: likedArtistIDs,
            starredSongIDs: starredSongIDs,
            starredAlbumIDs: starredAlbumIDs,
            starredArtistIDs: starredArtistIDs,
            searchResultsByQuery: searchResults,
            lyricsBySongID: lyrics,
            smartPlaylistSongIDsByID: [smartPlaylist.id: smartSongIDs],
            playlistSongIDsByID: playlistSongIDs
        )
    }

    private static func date(daysBefore: Int) -> Date {
        baseDate.addingTimeInterval(-Double(daysBefore) * 86_400)
    }

    private static func deterministicUUID(_ ordinal: Int) -> UUID {
        let hex = String(format: "%012x", ordinal)
        return UUID(uuidString: "00000000-0000-0000-0000-\(hex)")!
    }

    private static func makeSearchResults(
        songs: [Song],
        albums: [Album],
        artists: [Artist]
    ) -> [String: SearchResults] {
        func result(for query: String) -> SearchResults {
            let needle = query.lowercased()
            return SearchResults(
                artists: artists.filter { $0.name.lowercased().contains(needle) },
                albums: albums.filter { $0.name.lowercased().contains(needle) || $0.artist.lowercased().contains(needle) },
                songs: songs.filter {
                    $0.title.lowercased().contains(needle)
                        || $0.album.lowercased().contains(needle)
                        || $0.artist.lowercased().contains(needle)
                }
            )
        }

        return [
            "": SearchResults(artists: artists, albums: albums, songs: songs),
            "neon": result(for: "neon"),
            "glass": result(for: "glass"),
            "weather": result(for: "weather"),
            "atlas": result(for: "atlas"),
            "zzzz-no-match": SearchResults(artists: [], albums: [], songs: [])
        ]
    }

    /// Generate a small gradient/checker composition and encode it as a real
    /// PNG using ImageIO. The bytes contain no private or repository assets.
    private static func makeArtworkPNG(seed: String, size: Int) -> Data? {
        let width = max(32, size)
        let height = width
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let red = UInt8((hash >> 16) & 0x7F) &+ 64
        let green = UInt8((hash >> 8) & 0x7F) &+ 64
        let blue = UInt8(hash & 0x7F) &+ 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let diagonal = UInt8((x * 255 / max(width - 1, 1) + y * 255 / max(height - 1, 1)) / 2)
                let checker: UInt8 = ((x / max(width / 8, 1) + y / max(height / 8, 1)) % 2 == 0) ? 14 : 0
                pixels[index] = red &+ diagonal / 5 &+ checker
                pixels[index + 1] = green &+ (255 &- diagonal) / 7 &+ checker / 2
                pixels[index + 2] = blue &+ diagonal / 3
                pixels[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
