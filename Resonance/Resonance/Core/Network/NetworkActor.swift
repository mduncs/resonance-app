import Foundation

private final class PublicDemoSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(PublicDemoConfiguration.allowsNetworkURL(request.url) ? request : nil)
    }
}

enum SongLibraryFetchPath: String, Sendable {
    case emptyQuerySearch = "search3-empty-query"
    case albumEnumeration = "album-enumeration"
}

/// Whether a paginated library walk actually reached the end of the collection.
///
/// This distinction is load-bearing and must never be collapsed back into a
/// plain "it didn't throw" success. A walk that bails out early still returns
/// rows, and callers that treat a partial result as authoritative can conclude
/// the server's library shrank. Anything destructive (pruning rows the server
/// "no longer has") must be gated on `.complete`.
enum LibraryWalkOutcome: Sendable, Equatable {
    /// The server signalled the final page; every item was enumerated.
    case complete
    /// The walk gave up before the end. The payload is a partial result.
    case truncated(reason: String)

    var isComplete: Bool { self == .complete }

    var truncationReason: String? {
        if case let .truncated(reason) = self { return reason }
        return nil
    }
}

struct AlbumLibraryFetchResult: Sendable {
    let albums: [Album]
    let walk: LibraryWalkOutcome
}

struct SongLibraryFetchResult: Sendable {
    let songCount: Int
    let path: SongLibraryFetchPath
    let fallbackReason: String?
    let walk: LibraryWalkOutcome

    init(
        songCount: Int,
        path: SongLibraryFetchPath,
        fallbackReason: String?,
        walk: LibraryWalkOutcome = .complete
    ) {
        self.songCount = songCount
        self.path = path
        self.fallbackReason = fallbackReason
        self.walk = walk
    }
}

struct SongLibraryFallbackError: LocalizedError {
    let searchError: Error
    let fallbackError: Error

    var errorDescription: String? {
        "Empty-query search3 failed (\(searchError.localizedDescription)); "
            + "album-enumeration fallback also failed (\(fallbackError.localizedDescription))"
    }
}

actor NetworkActor {
    private let session: URLSession
    private let sessionDelegate: PublicDemoSessionDelegate
    private(set) var activeServer: Server?
    private var auth: SubsonicAuth?
    private var cacheActor: CacheActor?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let delegate = PublicDemoSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func setCacheActor(_ cache: CacheActor) {
        self.cacheActor = cache
    }

    func configure(server: Server, password: String) {
        guard PublicDemoConfiguration.allowsNetworkURL(server.url) else {
            self.activeServer = nil
            self.auth = nil
            return
        }
        self.activeServer = server
        self.auth = SubsonicAuth(username: server.username, password: password)
    }

    func resetConfiguration() {
        activeServer = nil
        auth = nil
        nativeToken = nil
    }

    // MARK: - Flexible Date Decoding

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)

        // Try ISO8601 first (with fractional seconds)
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Formatter.date(from: string) {
            return date
        }

        // Try common formats Navidrome uses
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss"] {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: string) {
                return date
            }
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(string)")
    }

    func fetch<T: SubsonicContent>(_ endpoint: SubsonicEndpoint) async throws -> T {
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        let url = try buildURL(server: server, endpoint: endpoint, auth: auth)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResonanceError.invalidResponse(statusCode: 0)
        }

        guard httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(NetworkActor.decodeDate)

        let subsonicResponse = try decoder.decode(SubsonicResponse<T>.self, from: data)

        if subsonicResponse.subsonicResponse.status == "failed",
           let error = subsonicResponse.subsonicResponse.error {
            throw ResonanceError.subsonicError(code: error.code, message: error.message)
        }

        guard let content = subsonicResponse.subsonicResponse.content else {
            throw ResonanceError.decodingFailed(type: String(describing: T.self), underlying: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No content")))
        }

        return content
    }

    // MARK: - Cached Fetch

    /// Fetches with response caching. Checks cache first, falls back to network.
    /// Cache TTL is 5 minutes (handled by CacheActor).
    private func fetchWithCache<T: SubsonicContent>(
        _ endpoint: SubsonicEndpoint,
        cacheKey: String
    ) async throws -> T {
        guard let server = activeServer else {
            throw ResonanceError.notConfigured
        }

        // Check cache first
        if let cache = cacheActor,
           let cachedData = await cache.getResponse(for: cacheKey, serverId: server.id) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(NetworkActor.decodeDate)
            if let response = try? decoder.decode(SubsonicResponse<T>.self, from: cachedData),
               let content = response.subsonicResponse.content {
                return content
            }
        }

        // Cache miss or stale - fetch from network
        guard let auth = auth else {
            throw ResonanceError.notConfigured
        }

        let url = try buildURL(server: server, endpoint: endpoint, auth: auth)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ResonanceError.invalidResponse(statusCode: 0)
        }

        guard httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(NetworkActor.decodeDate)

        let subsonicResponse = try decoder.decode(SubsonicResponse<T>.self, from: data)

        if subsonicResponse.subsonicResponse.status == "failed",
           let error = subsonicResponse.subsonicResponse.error {
            throw ResonanceError.subsonicError(code: error.code, message: error.message)
        }

        guard let content = subsonicResponse.subsonicResponse.content else {
            throw ResonanceError.decodingFailed(type: String(describing: T.self), underlying: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No content")))
        }

        // Cache successful response
        if let cache = cacheActor {
            try? await cache.cacheResponse(data, for: cacheKey, serverId: server.id)
        }

        return content
    }

    func streamURL(for songId: String, quality: TranscodingQuality = .original) throws -> URL {
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        var endpoint = SubsonicEndpoint.stream(id: songId)

        if let maxBitRate = quality.maxBitRate, let format = quality.format {
            endpoint = SubsonicEndpoint.stream(id: songId, maxBitRate: maxBitRate, format: format)
        }

        return try buildURL(server: server, endpoint: endpoint, auth: auth)
    }

    func coverArtURL(for coverArtId: String, size: Int = 300) throws -> URL {
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        let endpoint = SubsonicEndpoint.getCoverArt(id: coverArtId, size: size)
        return try buildURL(server: server, endpoint: endpoint, auth: auth)
    }

    func downloadData(from url: URL) async throws -> Data {
        guard PublicDemoConfiguration.allowsNetworkURL(url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return data
    }

    // MARK: - Playlist Songs

    func fetchPlaylistSongs(playlistId: String) async throws -> [Song] {
        let response: PlaylistResponse = try await fetch(.getPlaylist(id: playlistId))
        return (response.entry ?? []).map { $0.toSong() }
    }

    // MARK: - Album Songs

    func fetchAlbumSongs(albumId: String) async throws -> [Song] {
        let cacheKey = "getAlbum:\(albumId)"
        let response: AlbumResponse = try await fetchWithCache(.getAlbum(id: albumId), cacheKey: cacheKey)
        return (response.song ?? []).map { $0.toSong() }
    }

    // MARK: - Artist Detail

    func fetchArtist(id: String) async throws -> ArtistDetail {
        let response: ArtistResponse = try await fetch(.getArtist(id: id))
        let albums = (response.album ?? []).map { $0.toAlbum() }

        return ArtistDetail(
            id: response.id,
            name: response.name,
            albumCount: response.albumCount ?? albums.count,
            coverArt: response.coverArt,
            starred: response.starred,
            albums: albums
        )
    }

    // MARK: - Similar Songs

    func getSimilarSongs(id: String, count: Int) async throws -> [Song] {
        let response: SimilarSongsResponse = try await fetch(.getSimilarSongs(id: id, count: count))
        return (response.song ?? []).map { $0.toSong() }
    }

    // MARK: - Internet Radio

    func fetchInternetRadioStations() async throws -> [InternetRadioStation] {
        let response: InternetRadioStationsResponse = try await fetchWithCache(
            .getInternetRadioStations,
            cacheKey: "getInternetRadioStations"
        )

        return (response.internetRadioStation ?? []).compactMap { $0.toInternetRadioStation() }
    }

    // MARK: - Star / Unstar

    func star(id: String, type: StarType) async throws {
        let endpoint: SubsonicEndpoint
        switch type {
        case .song:
            endpoint = .star(id: id, albumId: nil, artistId: nil)
        case .album:
            endpoint = .star(id: nil, albumId: id, artistId: nil)
        case .artist:
            endpoint = .star(id: nil, albumId: nil, artistId: id)
        }

        let _: EmptyResponse = try await fetch(endpoint)
    }

    func unstar(id: String, type: StarType) async throws {
        let endpoint: SubsonicEndpoint
        switch type {
        case .song:
            endpoint = .unstar(id: id, albumId: nil, artistId: nil)
        case .album:
            endpoint = .unstar(id: nil, albumId: id, artistId: nil)
        case .artist:
            endpoint = .unstar(id: nil, albumId: nil, artistId: id)
        }

        let _: EmptyResponse = try await fetch(endpoint)
    }

    // MARK: - Rating

    func setRating(id: String, rating: Int) async throws {
        let _: EmptyResponse = try await fetch(.setRating(id: id, rating: rating))
    }

    // MARK: - Ping

    func ping() async throws -> PingResponse {
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        return try await ping(server: server, auth: auth)
    }

    func ping(server: Server, password: String) async throws -> PingResponse {
        try await ping(server: server, auth: SubsonicAuth(username: server.username, password: password))
    }

    private func ping(server: Server, auth: SubsonicAuth) async throws -> PingResponse {
        let url = try buildURL(server: server, endpoint: .ping, auth: auth)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Parse the response to get server info
        struct PingWrapper: Decodable {
            let subsonicResponse: PingBody

            enum CodingKeys: String, CodingKey {
                case subsonicResponse = "subsonic-response"
            }
        }

        struct PingBody: Decodable {
            let status: String
            let version: String
            let type: String?
            let serverVersion: String?
            let error: SubsonicErrorBody?
        }

        let decoder = JSONDecoder()
        let pingWrapper = try decoder.decode(PingWrapper.self, from: data)

        if pingWrapper.subsonicResponse.status == "failed",
           let error = pingWrapper.subsonicResponse.error {
            throw ResonanceError.subsonicError(code: error.code, message: error.message)
        }

        return PingResponse(
            serverName: server.name,
            version: pingWrapper.subsonicResponse.version,
            type: pingWrapper.subsonicResponse.type ?? "subsonic"
        )
    }

    // MARK: - Delete Playlist

    func deletePlaylist(id: String) async throws {
        let _: EmptyResponse = try await fetch(.deletePlaylist(id: id))
    }

    // MARK: - Cover Art Data

    func fetchCoverArt(id: String, size: Int) async throws -> Data {
        let url = try coverArtURL(for: id, size: size)
        return try await downloadData(from: url)
    }

    // MARK: - Library Fetching

    /// Music folder filter from Library settings. nil = all folders.
    private var activeMusicFolderId: String? {
        let id = UserDefaults.standard.string(forKey: "libraryMusicFolderId") ?? ""
        return id.isEmpty ? nil : id
    }

    func fetchAlbums(
        type: AlbumListType = .alphabeticalByName,
        size: Int = 500,
        offset: Int = 0
    ) async throws -> [Album] {
        let folderId = activeMusicFolderId
        let cacheKey = "getAlbumList2:\(type.rawValue):\(size):\(offset):\(folderId ?? "all")"
        let endpoint = SubsonicEndpoint.getAlbumList2(type: type, size: size, offset: offset, musicFolderId: folderId)
        let response: AlbumListResponse = try await fetchWithCache(endpoint, cacheKey: cacheKey)
        return (response.album ?? []).map { $0.toAlbum() }
    }

    /// Fetch all albums from the server with pagination.
    /// Optional onPage callback receives accumulated albums after each page for incremental display.
    ///
    /// Termination is delegated to `LibraryPageWalker`; see it for why a page of
    /// pure duplicates must not be treated as the end of the library.
    func fetchAllAlbums(
        type: AlbumListType = .alphabeticalByName,
        pageSize: Int = 500,
        onPage: (@Sendable ([Album]) -> Void)? = nil
    ) async throws -> AlbumLibraryFetchResult {
        var allAlbums: [Album] = []
        var seenIds = Set<String>()
        var offset = 0
        var walker = LibraryPageWalker(pageSize: pageSize, label: "album")

        while true {
            let batch = try await fetchAlbums(type: type, size: pageSize, offset: offset)
            let newAlbums = batch.filter { seenIds.insert($0.id).inserted }
            allAlbums.append(contentsOf: newAlbums)

            onPage?(allAlbums)

            switch walker.step(
                batchCount: batch.count,
                newItemCount: newAlbums.count,
                offset: offset,
                totalSoFar: allAlbums.count
            ) {
            case .stop(let outcome):
                if let reason = outcome.truncationReason {
                    print("[NetworkActor] \(reason)")
                }
                return AlbumLibraryFetchResult(albums: allAlbums, walk: outcome)
            case .advance:
                offset += batch.count
            }
        }
    }

    func fetchArtists() async throws -> [Artist] {
        let folderId = activeMusicFolderId
        let cacheKey = "getArtists:\(folderId ?? "all")"
        let response: ArtistsResponse = try await fetchWithCache(.getArtists(musicFolderId: folderId), cacheKey: cacheKey)
        return response.index.flatMap { $0.artist.map { $0.toArtist() } }
    }

    func fetchRandomSongs(size: Int = 500) async throws -> [Song] {
        let response: RandomSongsResponse = try await fetch(
            .getRandomSongs(size: size, genre: nil, musicFolderId: activeMusicFolderId)
        )
        return (response.song ?? []).map { $0.toSong() }
    }

    func search(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20
    ) async throws -> SearchResults {
        let response: SearchResult3Response = try await fetch(
            .search3(query: query, artistCount: artistCount, artistOffset: 0, albumCount: albumCount, albumOffset: 0, songCount: songCount, songOffset: 0)
        )
        return SearchResults(
            artists: (response.artist ?? []).map { $0.toArtist() },
            albums: (response.album ?? []).map { $0.toAlbum() },
            songs: (response.song ?? []).map { $0.toSong() }
        )
    }


    /// Fetch a single page of songs via search3.
    func fetchSongPage(offset: Int, pageSize: Int = 500) async throws -> [Song] {
        let response: SearchResult3Response = try await fetch(
            .search3(query: "", artistCount: 0, artistOffset: 0, albumCount: 0, albumOffset: 0, songCount: pageSize, songOffset: offset)
        )
        return (response.song ?? []).map { $0.toSong() }
    }

    /// Fetch every song while emitting only each newly fetched delta.
    ///
    /// Empty-query `search3` is not implemented consistently across OpenSubsonic
    /// servers. If its first page fails, or is empty while albums exist, use the
    /// deliberately separate album-enumeration path. Later search-page failures
    /// remain real failures: callers have already persisted earlier deltas and
    /// should record the partial result rather than silently changing strategies.
    func fetchAllSongs(
        pageSize: Int = 500,
        onPage: (@Sendable ([Song]) async throws -> Void)? = nil
    ) async throws -> SongLibraryFetchResult {
        var seenIds = Set<String>()
        var offset = 0
        var songCount = 0
        var walker = LibraryPageWalker(pageSize: pageSize, label: "song")

        while true {
            let response: SearchResult3Response
            do {
                response = try await fetch(
                    .search3(
                        query: "",
                        artistCount: 0,
                        artistOffset: 0,
                        albumCount: 0,
                        albumOffset: 0,
                        songCount: pageSize,
                        songOffset: offset
                    )
                )
            } catch {
                guard offset == 0 else { throw error }
                print("[NetworkActor] Empty-query search3 failed; using album-enumeration song sync: \(error.localizedDescription)")
                do {
                    let albumResult = try await fetchAllAlbums()
                    return try await fetchAllSongsByAlbum(
                        albumResult.albums,
                        fallbackReason: error.localizedDescription,
                        albumWalk: albumResult.walk,
                        onPage: onPage
                    )
                } catch let fallbackError {
                    throw SongLibraryFallbackError(searchError: error, fallbackError: fallbackError)
                }
            }

            let batch = (response.song ?? []).map { $0.toSong() }
            let newSongs = batch.filter { seenIds.insert($0.id).inserted }

            if offset == 0, batch.isEmpty {
                let albumResult = try await fetchAllAlbums()
                guard !albumResult.albums.isEmpty else {
                    print("[NetworkActor] Empty-query search3 returned no songs and the server returned no albums")
                    return SongLibraryFetchResult(
                        songCount: 0,
                        path: .emptyQuerySearch,
                        fallbackReason: nil,
                        walk: .complete
                    )
                }

                let reason = "empty-query search3 returned an empty first page while \(albumResult.albums.count) albums exist"
                print("[NetworkActor] \(reason); using album-enumeration song sync")
                return try await fetchAllSongsByAlbum(
                    albumResult.albums,
                    fallbackReason: reason,
                    albumWalk: albumResult.walk,
                    onPage: onPage
                )
            }

            if !newSongs.isEmpty {
                try await onPage?(newSongs)
                songCount += newSongs.count
            }

            switch walker.step(
                batchCount: batch.count,
                newItemCount: newSongs.count,
                offset: offset,
                totalSoFar: songCount
            ) {
            case .stop(let outcome):
                if let reason = outcome.truncationReason {
                    print("[NetworkActor] \(reason)")
                }
                return SongLibraryFetchResult(
                    songCount: songCount,
                    path: .emptyQuerySearch,
                    fallbackReason: nil,
                    walk: outcome
                )
            case .advance:
                offset += batch.count
            }
        }
    }

    /// Compatibility path for servers that reject or mishandle empty searches.
    /// Each album is persisted as it completes, so a later album failure leaves
    /// earlier work durable and visible to scheduler diagnostics.
    private func fetchAllSongsByAlbum(
        _ albums: [Album],
        fallbackReason: String,
        albumWalk: LibraryWalkOutcome,
        onPage: (@Sendable ([Song]) async throws -> Void)?
    ) async throws -> SongLibraryFetchResult {
        var seenIds = Set<String>()
        var songCount = 0

        for album in albums {
            let albumSongs = try await fetchAlbumSongs(albumId: album.id)
            let newSongs = albumSongs.filter { seenIds.insert($0.id).inserted }
            guard !newSongs.isEmpty else { continue }

            try await onPage?(newSongs)
            songCount += newSongs.count
        }

        // This path can only enumerate songs belonging to albums it was given,
        // so a truncated album walk necessarily yields a truncated song walk.
        let walk: LibraryWalkOutcome = {
            guard let albumReason = albumWalk.truncationReason else { return .complete }
            return .truncated(reason: "album-enumeration song sync inherited a partial album list: \(albumReason)")
        }()

        return SongLibraryFetchResult(
            songCount: songCount,
            path: .albumEnumeration,
            fallbackReason: fallbackReason,
            walk: walk
        )
    }

    func fetchPlaylists() async throws -> [Playlist] {
        let cacheKey = "getPlaylists"
        let response: PlaylistsResponse = try await fetchWithCache(.getPlaylists(username: nil), cacheKey: cacheKey)
        return (response.playlist ?? []).map { $0.toPlaylist() }
    }

    func fetchGenres() async throws -> [Genre] {
        let response: GenresResponse = try await fetch(.getGenres)
        return (response.genre ?? []).map { $0.toGenre() }
    }

    func fetchMusicFolders() async throws -> [MusicFolder] {
        let response: MusicFoldersResponse = try await fetch(.getMusicFolders)
        return (response.musicFolder ?? []).map { $0.toMusicFolder() }
    }

    func fetchMusicDirectory(id: String) async throws -> MusicDirectory {
        let response: MusicDirectoryResponse = try await fetch(.getMusicDirectory(id: id))
        return response.toMusicDirectory()
    }

    func fetchIndexes(musicFolderId: String?, folderName: String) async throws -> MusicDirectory {
        let response: IndexesResponse = try await fetch(.getIndexes(musicFolderId: musicFolderId))
        return response.toMusicDirectory(folderName: folderName)
    }

    // MARK: - Starred Content

    func fetchStarred2() async throws -> StarredContent {
        let response: Starred2Response = try await fetch(.getStarred2(musicFolderId: activeMusicFolderId))
        return StarredContent(
            artists: (response.artist ?? []).map { $0.toArtist() },
            albums: (response.album ?? []).map { $0.toAlbum() },
            songs: (response.song ?? []).map { $0.toSong() }
        )
    }

    // MARK: - Songs By Genre

    func fetchSongsByGenre(genre: String, count: Int, offset: Int) async throws -> [Song] {
        let response: SongsByGenreResponse = try await fetch(
            .getSongsByGenre(genre: genre, count: count, offset: offset)
        )
        return (response.song ?? []).map { $0.toSong() }
    }

    // MARK: - Lyrics

    func fetchLyrics(artist: String?, title: String?) async throws -> String? {
        let response: LyricsResponse = try await fetch(.getLyrics(artist: artist, title: title))
        return response.value
    }

    // MARK: - Scrobble

    func scrobble(id: String, submission: Bool) async throws {
        let _: EmptyResponse = try await fetch(.scrobble(id: id, time: Date(), submission: submission))
    }

    func scrobble(id: String, time: Date?, submission: Bool) async throws {
        let _: EmptyResponse = try await fetch(.scrobble(id: id, time: time, submission: submission))
    }

    // MARK: - Create Playlist

    func createPlaylist(name: String, songIds: [String]) async throws {
        let _: EmptyResponse = try await fetch(.createPlaylist(name: name, songIds: songIds))
    }

    // MARK: - Update Playlist

    func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) async throws {
        let _: EmptyResponse = try await fetch(.updatePlaylist(
            id: id,
            name: name,
            comment: comment,
            songIdsToAdd: songIdsToAdd,
            songIndexesToRemove: songIndexesToRemove
        ))
    }

    // MARK: - Start Library Scan

    func startScan() async throws {
        let _: EmptyResponse = try await fetch(.startScan)
    }

    // MARK: - Navidrome Native API (JWT auth, used for file path lookups)

    private var nativeToken: String?

    /// Authenticate with navidrome's native API and get a JWT token.
    /// Reuses the same username/password as subsonic auth.
    private func authenticateNative() async throws -> String {
        if let token = nativeToken { return token }

        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        var components = URLComponents(url: server.url, resolvingAgainstBaseURL: true)!
        components.path = "/auth/login"

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // SubsonicAuth stores the password privately — we need the raw password.
        // Re-extract from keychain via the server.
        let password = auth.rawPassword
        let body = try JSONSerialization.data(withJSONObject: [
            "username": server.username,
            "password": password
        ])
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ResonanceError.authenticationFailed(reason: "Native API login failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw ResonanceError.authenticationFailed(reason: "Native API response missing token")
        }

        self.nativeToken = token
        return token
    }

    /// Fetch a song's file path from navidrome's native API.
    /// Returns (path: relative path, libraryPath: library base directory).
    func fetchSongFilePath(id: String) async throws -> (path: String, libraryPath: String) {
        let token = try await authenticateNative()

        guard let server = activeServer else {
            throw ResonanceError.notConfigured
        }

        var components = URLComponents(url: server.url, resolvingAgainstBaseURL: true)!
        components.path = "/api/song/\(id)"

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")

        let (data, response) = try await session.data(for: request)

        // Token may have expired — retry once
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            self.nativeToken = nil
            let newToken = try await authenticateNative()
            request.setValue("Bearer \(newToken)", forHTTPHeaderField: "x-nd-authorization")
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let httpRetry = retryResponse as? HTTPURLResponse, httpRetry.statusCode == 200 else {
                throw ResonanceError.authenticationFailed(reason: "Native API re-auth failed")
            }
            return try parseSongPath(from: retryData)
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try parseSongPath(from: data)
    }

    private func parseSongPath(from data: Data) throws -> (path: String, libraryPath: String) {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let path = json?["path"] as? String else {
            throw ResonanceError.subsonicError(code: 0, message: "Song response missing 'path' field")
        }
        // libraryPath may not exist in all navidrome versions — fall back to empty
        let libraryPath = (json?["libraryPath"] as? String) ?? ""
        return (path: path, libraryPath: libraryPath)
    }

    /// Clear native API token (e.g., on server disconnect)
    func clearNativeToken() {
        nativeToken = nil
    }

    private func buildURL(server: Server, endpoint: SubsonicEndpoint, auth: SubsonicAuth) throws -> URL {
        guard PublicDemoConfiguration.allowsNetworkURL(server.url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }
        var components = URLComponents(url: server.url, resolvingAgainstBaseURL: true)!
        components.path = "/rest/\(endpoint.path)"

        var queryItems = auth.authParameters().map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(contentsOf: endpoint.queryItems)

        components.queryItems = queryItems

        guard let url = components.url else {
            throw ResonanceError.invalidURL
        }

        return url
    }
}

// MARK: - Retry Wrapper

func withRetry<T>(
    maxAttempts: Int = 3,
    delay: Duration = .seconds(1),
    backoff: Double = 2.0,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 0..<maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error

            // Don't retry auth failures or not found
            if let resonanceError = error as? ResonanceError {
                switch resonanceError {
                case .authenticationFailed, .subsonicError(code: 40, _), .subsonicError(code: 70, _):
                    throw error
                default:
                    break
                }
            }

            if attempt < maxAttempts - 1 {
                let waitTime = Double(delay.components.seconds) * pow(backoff, Double(attempt))
                try await Task.sleep(for: .seconds(waitTime))
            }
        }
    }

    throw lastError!
}
