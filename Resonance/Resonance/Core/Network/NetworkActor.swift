import Foundation

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

/// Transport audit for fixture launches. A fixture is allowed to satisfy
/// loader calls from local catalog data, but it must never issue a URLSession
/// request. `blockedCallCount` is useful evidence when a view accidentally
/// reaches an unsupported transport path.
struct NetworkFixtureAuditSnapshot: Sendable, Equatable {
    let transportRequestCount: Int
    let blockedCallCount: Int
    let scrobbleAttemptCount: Int

    /// Compatibility aliases for capture/test code that uses shorter names.
    var requestCount: Int { transportRequestCount }
    var blockedCount: Int { blockedCallCount }
}

typealias NetworkAuditSnapshot = NetworkFixtureAuditSnapshot

actor NetworkActor {
    private let session: URLSession
    private let sessionDelegate: PublicDemoSessionDelegate
    private let fixtureCatalog: ParityFixtureCatalog?
    private let fixtureConfiguration: DeterministicCaptureFixture.Configuration?
    private var transportRequestCount = 0
    private var blockedCallCount = 0
    private var scrobbleAttemptCount = 0
    private(set) var activeServer: Server?
    private var auth: SubsonicAuth?
    private var cacheActor: CacheActor?

    init(
        catalog: ParityFixtureCatalog? = nil,
        configuration: DeterministicCaptureFixture.Configuration? = nil
    ) {
        let isFixture = catalog != nil || configuration != nil
        let config = URLSessionConfiguration.ephemeral
        if isFixture {
            // Fixture responses are local; do not initialize shared persistent
            // cache, cookie or credential storage for this inert transport.
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
        }
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let delegate = PublicDemoSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.fixtureCatalog = catalog ?? (configuration?.isAtlas == true ? .standard : nil)
        self.fixtureConfiguration = configuration
    }

    /// Explicitly named fixture initializer for call sites that want the
    /// launch mode to be obvious. Production callers should continue using
    /// `NetworkActor()`.
    init(
        fixtureCatalog: ParityFixtureCatalog,
        configuration: DeterministicCaptureFixture.Configuration? = nil
    ) {
        self.init(catalog: fixtureCatalog, configuration: configuration)
    }

    init(
        fixtureCatalog: ParityFixtureCatalog,
        fixtureConfiguration: DeterministicCaptureFixture.Configuration? = nil
    ) {
        self.init(catalog: fixtureCatalog, configuration: fixtureConfiguration)
    }

    /// Construct from an atlas configuration and the standard catalog.
    init(configuration: DeterministicCaptureFixture.Configuration) {
        self.init(catalog: configuration.isAtlas ? .standard : nil, configuration: configuration)
    }

    var isFixtureMode: Bool { fixtureCatalog != nil }

    func auditSnapshot() -> NetworkFixtureAuditSnapshot {
        NetworkFixtureAuditSnapshot(
            transportRequestCount: transportRequestCount,
            blockedCallCount: blockedCallCount,
            scrobbleAttemptCount: scrobbleAttemptCount
        )
    }

    /// Alias used by launch diagnostics.
    func fixtureAuditSnapshot() -> NetworkFixtureAuditSnapshot { auditSnapshot() }

    private func fixtureBlocked(_ operation: String) -> ResonanceError {
        blockedCallCount += 1
        _ = operation
        return .networkUnavailable
    }

    private func recordTransportRequest() {
        transportRequestCount += 1
    }

    func setCacheActor(_ cache: CacheActor) {
        guard fixtureCatalog == nil else { return }
        self.cacheActor = cache
    }

    private var configurationGeneration: UInt64 = 0

    func configure(server: Server, password: String) {
        guard fixtureCatalog == nil else { return }
        configurationGeneration &+= 1
        guard PublicDemoConfiguration.allowsNetworkURL(server.url) else {
            activeServer = nil
            auth = nil
            nativeToken = nil
            return
        }
        self.activeServer = server
        self.auth = SubsonicAuth(username: server.username, password: password)
    }

    func resetConfiguration() {
        configurationGeneration &+= 1
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

        // Standard timestamps may omit fractional seconds entirely.
        iso8601Formatter.formatOptions = [.withInternetDateTime]
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
        try Task.checkCancellation()
        guard fixtureCatalog == nil else {
            throw fixtureBlocked("fetch:\(endpoint.path)")
        }
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        let url = try buildURL(server: server, endpoint: endpoint, auth: auth)
        recordTransportRequest()
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()

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
        cacheKey: String,
        forceRefresh: Bool = false
    ) async throws -> T {
        try Task.checkCancellation()
        guard fixtureCatalog == nil else {
            throw fixtureBlocked("fetchWithCache:\(endpoint.path)")
        }
        // Keep server and authentication from the same configuration across
        // the cache await; never combine an old server with newer credentials.
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        // Check cache first
        if !forceRefresh, let cache = cacheActor,
           let cachedData = await cache.getResponse(for: cacheKey, serverId: server.id) {
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(NetworkActor.decodeDate)
            if let response = try? decoder.decode(SubsonicResponse<T>.self, from: cachedData),
               let content = response.subsonicResponse.content {
                try Task.checkCancellation()
                return content
            }
        }

        // Cache miss or stale - fetch from network
        try Task.checkCancellation()
        let url = try buildURL(server: server, endpoint: endpoint, auth: auth)
        recordTransportRequest()
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()

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
            try Task.checkCancellation()
            try? await cache.cacheResponse(data, for: cacheKey, serverId: server.id)
            try Task.checkCancellation()
        }

        return content
    }

    func streamURL(for songId: String, quality: TranscodingQuality = .original) throws -> URL {
        if fixtureCatalog != nil {
            throw fixtureBlocked("streamURL")
        }
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
        if fixtureCatalog != nil {
            throw fixtureBlocked("coverArtURL")
        }
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        let endpoint = SubsonicEndpoint.getCoverArt(id: coverArtId, size: size)
        return try buildURL(server: server, endpoint: endpoint, auth: auth)
    }

    func downloadData(from url: URL) async throws -> Data {
        guard fixtureCatalog == nil else {
            throw fixtureBlocked("downloadData")
        }
        guard PublicDemoConfiguration.allowsNetworkURL(url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }
        recordTransportRequest()
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ResonanceError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return data
    }

    // MARK: - Playlist Songs

    func fetchPlaylistSongs(playlistId: String, expectedServerID: UUID? = nil) async throws -> [Song] {
        try Task.checkCancellation()
        if let catalog = fixtureCatalog {
            // Build this computed catalog index once, not once per occurrence.
            // The scale fixture contains 50k entries in a 100k-song library.
            let songsByID = catalog.songByID
            return try catalog.playlistSongIDsByID[playlistId, default: []].compactMap {
                try Task.checkCancellation()
                return songsByID[$0]
            }
        }
        if let expectedServerID, activeServer?.id != expectedServerID {
            throw ResonanceError.notConfigured
        }
        let response: PlaylistResponse = try await fetch(.getPlaylist(id: playlistId))
        return (response.entry ?? []).map { $0.toSong() }
    }

    // MARK: - Album Songs

    func fetchAlbum(id: String, expectedServerID: UUID) async throws -> Album {
        if let catalog = fixtureCatalog, let album = catalog.albumByID[id] { return album }
        try Task.checkCancellation()
        guard activeServer?.id == expectedServerID else { throw ResonanceError.notConfigured }
        let generation = configurationGeneration
        let response: AlbumResponse = try await fetchWithCache(
            .getAlbum(id: id), cacheKey: "getAlbum:\(id)"
        )
        try Task.checkCancellation()
        guard configurationGeneration == generation,
              activeServer?.id == expectedServerID else { throw CancellationError() }
        return response.toAlbum()
    }

    func fetchAlbumSongs(albumId: String, expectedServerID: UUID? = nil) async throws -> [Song] {
        if let catalog = fixtureCatalog {
            return (catalog.songsByAlbumID[albumId] ?? []).sortedForAlbum()
        }
        try Task.checkCancellation()
        guard let serverID = expectedServerID ?? activeServer?.id,
              activeServer?.id == serverID else { throw ResonanceError.notConfigured }
        let generation = configurationGeneration
        let cacheKey = "getAlbum:\(albumId)"
        let response: AlbumResponse = try await fetchWithCache(.getAlbum(id: albumId), cacheKey: cacheKey)
        try Task.checkCancellation()
        guard configurationGeneration == generation, activeServer?.id == serverID else { throw CancellationError() }
        let releaseDate = MediaReleaseDate(storageValue: response.releaseDate?.storageValue)
        return (response.song ?? []).map {
            var song = $0.toSong()
            song.releaseDate = releaseDate
            return song
        }.sortedForAlbum()
    }

    // MARK: - Artist Detail

    func fetchArtist(id: String, expectedServerID: UUID? = nil) async throws -> ArtistDetail {
        if let catalog = fixtureCatalog, let artist = catalog.artistByID[id] {
            return ArtistDetail(
                id: artist.id,
                name: artist.name,
                albumCount: artist.albumCount,
                coverArt: artist.coverArt,
                starred: artist.starred,
                albums: catalog.albumsByArtistID[id] ?? []
            )
        }
        if fixtureCatalog != nil { return ArtistDetail(id: id, name: "Unknown Artist", albumCount: 0, coverArt: nil, starred: nil, albums: []) }
        try Task.checkCancellation()
        guard let serverID = expectedServerID ?? activeServer?.id,
              activeServer?.id == serverID else { throw ResonanceError.notConfigured }
        let generation = configurationGeneration
        let response: ArtistResponse = try await fetch(.getArtist(id: id))
        try Task.checkCancellation()
        guard configurationGeneration == generation, activeServer?.id == serverID else { throw CancellationError() }
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

    func getSimilarSongs(id: String, count: Int, expectedServerID: UUID? = nil) async throws -> [Song] {
        try Task.checkCancellation()
        if let catalog = fixtureCatalog {
            guard let seed = catalog.songByID[id] else { return [] }
            return Array(catalog.songs.filter {
                $0.id != id && ($0.artistId == seed.artistId || $0.genre == seed.genre)
            }.prefix(max(0, count)))
        }
        guard let serverID = expectedServerID ?? activeServer?.id,
              activeServer?.id == serverID else { throw CancellationError() }
        let generation = configurationGeneration
        do {
            let response: SimilarSongsResponse = try await fetch(.getSimilarSongs(id: id, count: count))
            try Task.checkCancellation()
            guard configurationGeneration == generation, activeServer?.id == serverID else { throw CancellationError() }
            return (response.song ?? []).map { $0.toSong() }
        } catch {
            guard configurationGeneration == generation, activeServer?.id == serverID else { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Internet Radio

    func fetchInternetRadioStations() async throws -> [InternetRadioStation] {
        if fixtureCatalog != nil { return [] }
        let response: InternetRadioStationsResponse = try await fetchWithCache(
            .getInternetRadioStations,
            cacheKey: "getInternetRadioStations"
        )

        return (response.internetRadioStation ?? []).compactMap { $0.toInternetRadioStation() }
    }

    // MARK: - Star / Unstar

    func star(id: String, type: StarType, expectedServerID: UUID? = nil) async throws {
        if fixtureCatalog != nil { return }
        if let expectedServerID, activeServer?.id != expectedServerID {
            throw ResonanceError.notConfigured
        }
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

    func unstar(id: String, type: StarType, expectedServerID: UUID? = nil) async throws {
        if fixtureCatalog != nil { return }
        if let expectedServerID, activeServer?.id != expectedServerID {
            throw ResonanceError.notConfigured
        }
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
        if fixtureCatalog != nil { return }
        let _: EmptyResponse = try await fetch(.setRating(id: id, rating: rating))
    }

    // MARK: - Ping

    func ping() async throws -> PingResponse {
        if fixtureCatalog != nil {
            return PingResponse(
                serverName: ParityFixtureCatalog.serverName,
                version: "fixture-1.0",
                type: "parity-atlas"
            )
        }
        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }

        return try await ping(server: server, auth: auth)
    }

    func ping(server: Server, password: String) async throws -> PingResponse {
        if fixtureCatalog != nil {
            return PingResponse(
                serverName: ParityFixtureCatalog.serverName,
                version: "fixture-1.0",
                type: "parity-atlas"
            )
        }
        return try await ping(server: server, auth: SubsonicAuth(username: server.username, password: password))
    }

    private func ping(server: Server, auth: SubsonicAuth) async throws -> PingResponse {
        let url = try buildURL(server: server, endpoint: .ping, auth: auth)
        recordTransportRequest()
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
        if fixtureCatalog != nil { return }
        let _: EmptyResponse = try await fetch(.deletePlaylist(id: id))
    }

    // MARK: - Cover Art Data

    func fetchCoverArt(id: String, size: Int) async throws -> Data {
        if let catalog = fixtureCatalog {
            guard let data = catalog.artworkPNGData(for: id, size: size) else {
                throw ResonanceError.notConfigured
            }
            return data
        }
        let url = try coverArtURL(for: id, size: size)
        return try await downloadData(from: url)
    }

    // MARK: - Library Fetching

    /// Music folder filter from Library settings. nil = all folders.
    private var activeMusicFolderId: String? {
        if fixtureCatalog != nil { return nil }
        let id = UserDefaults.standard.string(forKey: "libraryMusicFolderId") ?? ""
        return id.isEmpty ? nil : id
    }

    private func validateLibraryFetchOrigin(
        serverID: UUID,
        musicFolderID: String?,
        configurationGeneration expectedGeneration: UInt64? = nil
    ) throws {
        try Task.checkCancellation()
        guard activeServer?.id == serverID,
              activeMusicFolderId == musicFolderID,
              expectedGeneration.map({ configurationGeneration == $0 }) ?? true else {
            throw CancellationError()
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func fetchAlbums(
        type: AlbumListType = .alphabeticalByName,
        size: Int = 500,
        offset: Int = 0,
        expectedServerID: UUID? = nil
    ) async throws -> [Album] {
        if let catalog = fixtureCatalog {
            var albums = catalog.albums
            switch type {
            case .alphabeticalByName:
                albums.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            case .alphabeticalByArtist:
                albums.sort {
                    if $0.artist != $1.artist { return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .newest:
                albums.sort { ($0.year ?? 0) > ($1.year ?? 0) }
            case .byYear:
                albums.sort { ($0.year ?? 0) > ($1.year ?? 0) }
            case .byGenre:
                albums.sort {
                    let lhsGenre = $0.genre ?? ""
                    let rhsGenre = $1.genre ?? ""
                    if lhsGenre != rhsGenre { return lhsGenre.localizedCaseInsensitiveCompare(rhsGenre) == .orderedAscending }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .starred:
                albums.sort { ($0.starred != nil ? 0 : 1, $0.name) < ($1.starred != nil ? 0 : 1, $1.name) }
            case .random, .highest, .frequent, .recent:
                // A fixed order is preferable to true randomness in captures.
                break
            }
            let safeOffset = max(0, offset)
            guard safeOffset < albums.count, size > 0 else { return [] }
            return Array(albums.dropFirst(safeOffset).prefix(size))
        }
        try Task.checkCancellation()
        guard let serverID = expectedServerID ?? activeServer?.id,
              activeServer?.id == serverID else { throw ResonanceError.notConfigured }
        let generation = configurationGeneration
        let folderId = activeMusicFolderId
        let cacheKey = "getAlbumList2:\(type.rawValue):\(size):\(offset):\(folderId ?? "all")"
        let endpoint = SubsonicEndpoint.getAlbumList2(type: type, size: size, offset: offset, musicFolderId: folderId)
        let response: AlbumListResponse = try await fetchWithCache(endpoint, cacheKey: cacheKey)
        try Task.checkCancellation()
        guard configurationGeneration == generation, activeServer?.id == serverID else { throw CancellationError() }
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
        expectedServerID: UUID? = nil,
        expectedMusicFolderID: String? = nil,
        expectedConfigurationGeneration: UInt64? = nil,
        onPage: (@Sendable ([Album]) -> Void)? = nil
    ) async throws -> AlbumLibraryFetchResult {
        try Task.checkCancellation()
        if let catalog = fixtureCatalog {
            onPage?(catalog.albums)
            try Task.checkCancellation()
            return AlbumLibraryFetchResult(albums: catalog.albums, walk: .complete)
        }
        guard let originServerID = expectedServerID ?? activeServer?.id else {
            throw ResonanceError.notConfigured
        }
        let originMusicFolderID = expectedServerID == nil ? activeMusicFolderId : expectedMusicFolderID
        let originGeneration = expectedConfigurationGeneration ?? configurationGeneration
        try validateLibraryFetchOrigin(
            serverID: originServerID,
            musicFolderID: originMusicFolderID,
            configurationGeneration: originGeneration
        )
        var allAlbums: [Album] = []
        var seenIds = Set<String>()
        var offset = 0
        var walker = LibraryPageWalker(pageSize: pageSize, label: "album")

        while true {
            try Task.checkCancellation()
            try validateLibraryFetchOrigin(
                serverID: originServerID,
                musicFolderID: originMusicFolderID,
                configurationGeneration: originGeneration
            )
            let batch = try await fetchAlbums(
                type: type, size: pageSize, offset: offset,
                expectedServerID: originServerID
            )
            try validateLibraryFetchOrigin(
                serverID: originServerID,
                musicFolderID: originMusicFolderID,
                configurationGeneration: originGeneration
            )
            let newAlbums = batch.filter { seenIds.insert($0.id).inserted }
            allAlbums.append(contentsOf: newAlbums)

            onPage?(allAlbums)
            try validateLibraryFetchOrigin(
                serverID: originServerID,
                musicFolderID: originMusicFolderID,
                configurationGeneration: originGeneration
            )

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

    func fetchArtists(
        expectedServerID: UUID? = nil,
        expectedMusicFolderID: String? = nil
    ) async throws -> [Artist] {
        if let catalog = fixtureCatalog { return catalog.artists }
        if let expectedServerID, activeServer?.id != expectedServerID {
            throw ResonanceError.notConfigured
        }
        let folderId = expectedServerID == nil ? activeMusicFolderId : expectedMusicFolderID
        let originGeneration = configurationGeneration
        if let expectedServerID {
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: folderId,
                configurationGeneration: originGeneration
            )
        }
        let cacheKey = "getArtists:\(folderId ?? "all")"
        let response: ArtistsResponse = try await fetchWithCache(.getArtists(musicFolderId: folderId), cacheKey: cacheKey)
        if let expectedServerID {
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: folderId,
                configurationGeneration: originGeneration
            )
        }
        return response.index.flatMap { $0.artist.map { $0.toArtist() } }
    }

    func fetchRandomSongs(size: Int = 500) async throws -> [Song] {
        if let catalog = fixtureCatalog { return Array(catalog.songs.prefix(max(0, size))) }
        let response: RandomSongsResponse = try await fetch(
            .getRandomSongs(size: size, genre: nil, musicFolderId: activeMusicFolderId)
        )
        return (response.song ?? []).map { $0.toSong() }
    }

    func search(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20,
        artistOffset: Int = 0,
        albumOffset: Int = 0,
        songOffset: Int = 0,
        expectedServerID: UUID? = nil
    ) async throws -> SearchResults {
        try Task.checkCancellation()
        if let catalog = fixtureCatalog {
            func page<T>(_ items: [T], offset: Int, count: Int) -> [T] {
                Array(items.dropFirst(max(0, offset)).prefix(max(0, count)))
            }
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches: SearchResults
            if let fixed = catalog.searchResultsByQuery[normalized] {
                matches = fixed
            } else if normalized.isEmpty {
                matches = SearchResults(artists: catalog.artists, albums: catalog.albums, songs: catalog.songs)
            } else {
                matches = SearchResults(
                    artists: catalog.artists.filter { $0.name.lowercased().contains(normalized) },
                    albums: catalog.albums.filter { $0.name.lowercased().contains(normalized) || $0.artist.lowercased().contains(normalized) },
                    songs: catalog.songs.filter {
                        $0.title.lowercased().contains(normalized)
                            || $0.album.lowercased().contains(normalized)
                            || $0.artist.lowercased().contains(normalized)
                    }
                )
            }
            return SearchResults(
                artists: page(matches.artists, offset: artistOffset, count: artistCount),
                albums: page(matches.albums, offset: albumOffset, count: albumCount),
                songs: page(matches.songs, offset: songOffset, count: songCount)
            )
        }
        guard let serverID = expectedServerID ?? activeServer?.id,
              activeServer?.id == serverID else { throw ResonanceError.notConfigured }
        let response: SearchResult3Response = try await fetch(
            .search3(query: query,
                     artistCount: max(0, artistCount), artistOffset: max(0, artistOffset),
                     albumCount: max(0, albumCount), albumOffset: max(0, albumOffset),
                     songCount: max(0, songCount), songOffset: max(0, songOffset))
        )
        try Task.checkCancellation()
        guard activeServer?.id == serverID else { throw ResonanceError.notConfigured }
        return SearchResults(
            artists: (response.artist ?? []).map { $0.toArtist() },
            albums: (response.album ?? []).map { $0.toAlbum() },
            songs: (response.song ?? []).map { $0.toSong() }
        )
    }

    /// Enumerate all three search facets before Library admission filtering.
    /// A short page is not exhaustion: servers may impose a lower page-size cap.
    /// Offsets count raw records, while publication deduplicates IDs in server order.
    /// Repeated duplicate pages are a failure, never a successful partial search.
    func searchAll(query: String, expectedServerID: UUID? = nil) async throws -> SearchResults {
        let serverID = expectedServerID ?? activeServer?.id
        var artists: [Artist] = []
        var albums: [Album] = []
        var songs: [Song] = []
        var artistIDs = Set<String>(), albumIDs = Set<String>(), songIDs = Set<String>()
        var artistOffset = 0, albumOffset = 0, songOffset = 0
        var artistRepeats = 0, albumRepeats = 0, songRepeats = 0
        var artistsDone = false, albumsDone = false, songsDone = false

        func consume<T: Identifiable>(
            _ page: [T], into items: inout [T], seen: inout Set<String>,
            offset: inout Int, repeats: inout Int, facet: String
        ) throws -> Bool where T.ID == String {
            guard !page.isEmpty else { return true }
            let fresh = page.filter { seen.insert($0.id).inserted }
            repeats = fresh.isEmpty ? repeats + 1 : 0
            guard repeats < 3 else {
                throw ResonanceError.networkError(NSError(
                    domain: "Resonance.SearchPagination", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Search is incomplete: the server returned repeated \(facet) pages at offset \(offset)."]
                ))
            }
            items.append(contentsOf: fresh)
            offset += page.count
            return false
        }

        while !artistsDone || !albumsDone || !songsDone {
            try Task.checkCancellation()
            let page = try await search(
                query: query,
                artistCount: artistsDone ? 0 : 100,
                albumCount: albumsDone ? 0 : 100,
                songCount: songsDone ? 0 : 100,
                artistOffset: artistOffset, albumOffset: albumOffset, songOffset: songOffset,
                expectedServerID: serverID
            )
            try Task.checkCancellation()
            if fixtureCatalog == nil, activeServer?.id != serverID { throw ResonanceError.notConfigured }
            if !artistsDone {
                artistsDone = try consume(page.artists, into: &artists, seen: &artistIDs,
                                          offset: &artistOffset, repeats: &artistRepeats, facet: "artist")
            }
            if !albumsDone {
                albumsDone = try consume(page.albums, into: &albums, seen: &albumIDs,
                                         offset: &albumOffset, repeats: &albumRepeats, facet: "album")
            }
            if !songsDone {
                songsDone = try consume(page.songs, into: &songs, seen: &songIDs,
                                        offset: &songOffset, repeats: &songRepeats, facet: "song")
            }
        }
        return SearchResults(artists: artists, albums: albums, songs: songs)
    }


    /// Fetch a single page of songs via search3.
    func fetchSongPage(offset: Int, pageSize: Int = 500, expectedServerID: UUID? = nil) async throws -> [Song] {
        if let catalog = fixtureCatalog {
            let safeOffset = max(0, offset)
            guard safeOffset < catalog.songs.count, pageSize > 0 else { return [] }
            return Array(catalog.songs.dropFirst(safeOffset).prefix(pageSize))
        }
        if let expectedServerID, activeServer?.id != expectedServerID { throw ResonanceError.notConfigured }
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
        expectedServerID: UUID? = nil,
        expectedMusicFolderID: String? = nil,
        expectedConfigurationGeneration: UInt64? = nil,
        onPage: (@Sendable ([Song]) async throws -> Void)? = nil
    ) async throws -> SongLibraryFetchResult {
        try Task.checkCancellation()
        if let catalog = fixtureCatalog {
            try await onPage?(catalog.songs)
            try Task.checkCancellation()
            return SongLibraryFetchResult(
                songCount: catalog.songs.count,
                path: .emptyQuerySearch,
                fallbackReason: nil,
                walk: .complete
            )
        }
        guard let originServerID = expectedServerID ?? activeServer?.id else {
            throw ResonanceError.notConfigured
        }
        let originMusicFolderID = expectedServerID == nil ? activeMusicFolderId : expectedMusicFolderID
        let originGeneration = expectedConfigurationGeneration ?? configurationGeneration
        try validateLibraryFetchOrigin(
            serverID: originServerID,
            musicFolderID: originMusicFolderID,
            configurationGeneration: originGeneration
        )
        var seenIds = Set<String>()
        var offset = 0
        var songCount = 0
        var walker = LibraryPageWalker(pageSize: pageSize, label: "song")

        while true {
            try Task.checkCancellation()
            try validateLibraryFetchOrigin(
                serverID: originServerID,
                musicFolderID: originMusicFolderID,
                configurationGeneration: originGeneration
            )
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
                try Task.checkCancellation()
                if Self.isCancellation(error) { throw CancellationError() }
                try validateLibraryFetchOrigin(
                    serverID: originServerID,
                    musicFolderID: originMusicFolderID,
                    configurationGeneration: originGeneration
                )
                guard offset == 0 else { throw error }
                print("[NetworkActor] Empty-query search3 failed; using album-enumeration song sync: \(error.localizedDescription)")
                do {
                    let albumResult = try await fetchAllAlbums(
                        expectedServerID: originServerID,
                        expectedMusicFolderID: originMusicFolderID,
                        expectedConfigurationGeneration: originGeneration
                    )
                    return try await fetchAllSongsByAlbum(
                        albumResult.albums,
                        fallbackReason: error.localizedDescription,
                        albumWalk: albumResult.walk,
                        expectedServerID: originServerID,
                        expectedMusicFolderID: originMusicFolderID,
                        expectedConfigurationGeneration: originGeneration,
                        onPage: onPage
                    )
                } catch let fallbackError {
                    try Task.checkCancellation()
                    if Self.isCancellation(fallbackError) { throw CancellationError() }
                    try validateLibraryFetchOrigin(
                        serverID: originServerID,
                        musicFolderID: originMusicFolderID,
                        configurationGeneration: originGeneration
                    )
                    throw SongLibraryFallbackError(searchError: error, fallbackError: fallbackError)
                }
            }

            let batch = (response.song ?? []).map { $0.toSong() }
            try validateLibraryFetchOrigin(
                serverID: originServerID,
                musicFolderID: originMusicFolderID,
                configurationGeneration: originGeneration
            )
            let newSongs = batch.filter { seenIds.insert($0.id).inserted }

            if offset == 0, batch.isEmpty {
                let albumResult = try await fetchAllAlbums(
                    expectedServerID: originServerID,
                    expectedMusicFolderID: originMusicFolderID,
                    expectedConfigurationGeneration: originGeneration
                )
                try validateLibraryFetchOrigin(
                    serverID: originServerID,
                    musicFolderID: originMusicFolderID,
                    configurationGeneration: originGeneration
                )
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
                    expectedServerID: originServerID,
                    expectedMusicFolderID: originMusicFolderID,
                    expectedConfigurationGeneration: originGeneration,
                    onPage: onPage
                )
            }

            if !newSongs.isEmpty {
                try await onPage?(newSongs)
                try validateLibraryFetchOrigin(
                    serverID: originServerID,
                    musicFolderID: originMusicFolderID,
                    configurationGeneration: originGeneration
                )
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
        expectedServerID: UUID,
        expectedMusicFolderID: String?,
        expectedConfigurationGeneration: UInt64,
        onPage: (@Sendable ([Song]) async throws -> Void)?
    ) async throws -> SongLibraryFetchResult {
        var seenIds = Set<String>()
        var songCount = 0

        for album in albums {
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: expectedMusicFolderID,
                configurationGeneration: expectedConfigurationGeneration
            )
            let albumSongs = try await fetchAlbumSongs(
                albumId: album.id, expectedServerID: expectedServerID
            )
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: expectedMusicFolderID,
                configurationGeneration: expectedConfigurationGeneration
            )
            let newSongs = albumSongs.filter { seenIds.insert($0.id).inserted }
            guard !newSongs.isEmpty else { continue }

            try await onPage?(newSongs)
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: expectedMusicFolderID,
                configurationGeneration: expectedConfigurationGeneration
            )
            songCount += newSongs.count
        }

        try validateLibraryFetchOrigin(
            serverID: expectedServerID,
            musicFolderID: expectedMusicFolderID,
            configurationGeneration: expectedConfigurationGeneration
        )

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

    func fetchPlaylists(forceRefresh: Bool = false, expectedServerID: UUID? = nil) async throws -> [Playlist] {
        if let catalog = fixtureCatalog { return catalog.playlists }
        if let expectedServerID, activeServer?.id != expectedServerID { throw ResonanceError.notConfigured }
        let cacheKey = "getPlaylists"
        let response: PlaylistsResponse = try await fetchWithCache(.getPlaylists(username: nil), cacheKey: cacheKey, forceRefresh: forceRefresh)
        return (response.playlist ?? []).map { $0.toPlaylist() }
    }

    func fetchGenres() async throws -> [Genre] {
        if let catalog = fixtureCatalog { return catalog.genres }
        let response: GenresResponse = try await fetch(.getGenres)
        return (response.genre ?? []).map { $0.toGenre() }
    }

    func fetchMusicFolders() async throws -> [MusicFolder] {
        if let catalog = fixtureCatalog { return catalog.musicFolders }
        let response: MusicFoldersResponse = try await fetch(.getMusicFolders)
        return (response.musicFolder ?? []).map { $0.toMusicFolder() }
    }

    func fetchMusicDirectory(id: String) async throws -> MusicDirectory {
        if let catalog = fixtureCatalog {
            return catalog.directories[id] ?? MusicDirectory(id: id, name: id, parent: nil, children: [])
        }
        let response: MusicDirectoryResponse = try await fetch(.getMusicDirectory(id: id))
        return response.toMusicDirectory()
    }

    func fetchIndexes(musicFolderId: String?, folderName: String) async throws -> MusicDirectory {
        if let catalog = fixtureCatalog {
            if let folderId = musicFolderId, let directory = catalog.directories[folderId] {
                return directory
            }
            return catalog.directories.values.first
                ?? MusicDirectory(id: musicFolderId ?? "atlas-index", name: folderName, parent: nil, children: [])
        }
        let response: IndexesResponse = try await fetch(.getIndexes(musicFolderId: musicFolderId))
        return response.toMusicDirectory(folderName: folderName)
    }

    // MARK: - Starred Content

    func fetchStarred2(
        expectedServerID: UUID? = nil,
        expectedMusicFolderID: String? = nil
    ) async throws -> StarredContent {
        if let catalog = fixtureCatalog {
            return StarredContent(
                artists: catalog.artists.filter { catalog.starredArtistIDs.contains($0.id) },
                albums: catalog.albums.filter { catalog.starredAlbumIDs.contains($0.id) },
                songs: catalog.songs.filter { catalog.starredSongIDs.contains($0.id) }
            )
        }
        let folderID = expectedServerID == nil ? activeMusicFolderId : expectedMusicFolderID
        let originGeneration = configurationGeneration
        if let expectedServerID {
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: folderID,
                configurationGeneration: originGeneration
            )
        }
        let response: Starred2Response = try await fetch(.getStarred2(musicFolderId: folderID))
        if let expectedServerID {
            try validateLibraryFetchOrigin(
                serverID: expectedServerID,
                musicFolderID: folderID,
                configurationGeneration: originGeneration
            )
        }
        return StarredContent(
            artists: (response.artist ?? []).map { $0.toArtist() },
            albums: (response.album ?? []).map { $0.toAlbum() },
            songs: (response.song ?? []).map { $0.toSong() }
        )
    }

    // MARK: - Songs By Genre

    func fetchSongsByGenre(genre: String, count: Int, offset: Int) async throws -> [Song] {
        if let catalog = fixtureCatalog {
            let songs = catalog.songs.filter { $0.genre?.caseInsensitiveCompare(genre) == .orderedSame }
            let safeOffset = max(0, offset)
            guard safeOffset < songs.count, count > 0 else { return [] }
            return Array(songs.dropFirst(safeOffset).prefix(count))
        }
        let response: SongsByGenreResponse = try await fetch(
            .getSongsByGenre(genre: genre, count: count, offset: offset)
        )
        return (response.song ?? []).map { $0.toSong() }
    }

    // MARK: - Lyrics

    func fetchLyrics(artist: String?, title: String?, expectedServerID: UUID? = nil) async throws -> String? {
        if let catalog = fixtureCatalog {
            let candidate = catalog.songs.first { song in
                (artist == nil || song.artist.caseInsensitiveCompare(artist!) == .orderedSame)
                    && (title == nil || song.title.caseInsensitiveCompare(title!) == .orderedSame)
            }
            guard let song = candidate, let lyrics = catalog.lyricsBySongID[song.id] else { return nil }
            return lyrics.syncedLyrics ?? lyrics.plainLyrics
        }
        if let expectedServerID, activeServer?.id != expectedServerID {
            throw ResonanceError.notConfigured
        }
        let response: LyricsResponse = try await fetch(.getLyrics(artist: artist, title: title))
        return response.value
    }

    // MARK: - Scrobble

    func scrobble(id: String, submission: Bool) async throws {
        if fixtureCatalog != nil {
            scrobbleAttemptCount += 1
            throw fixtureBlocked("scrobble")
        }
        let _: EmptyResponse = try await fetch(.scrobble(id: id, time: Date(), submission: submission))
    }

    func scrobble(id: String, time: Date?, submission: Bool) async throws {
        if fixtureCatalog != nil {
            scrobbleAttemptCount += 1
            throw fixtureBlocked("scrobble")
        }
        let _: EmptyResponse = try await fetch(.scrobble(id: id, time: time, submission: submission))
    }

    // MARK: - Create Playlist

    func createPlaylist(name: String, songIds: [String], expectedServerID: UUID? = nil) async throws -> String {
        // Preserve inert fixture mutations; this ID never reaches transport.
        if fixtureCatalog != nil { return "fixture-created-playlist" }
        if let expectedServerID, activeServer?.id != expectedServerID { throw ResonanceError.notConfigured }
        let response: CreatedPlaylistResponse = try await fetch(.createPlaylist(name: name, songIds: songIds))
        return response.id
    }

    // Existing-playlist mode of createPlaylist replaces the complete entry list.
    // Keep this distinct from creation so a failed order save never creates a copy.
    func replacePlaylistSongs(id: String, songIds: [String], expectedServerID: UUID) async throws {
        if fixtureCatalog != nil { return }
        guard activeServer?.id == expectedServerID else { throw ResonanceError.notConfigured }
        let _: CreatedPlaylistResponse = try await fetch(.replacePlaylistSongs(id: id, songIds: songIds))
    }

    // MARK: - Update Playlist

    func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = [],
        expectedServerID: UUID? = nil
    ) async throws {
        if fixtureCatalog != nil { return }
        if let expectedServerID, activeServer?.id != expectedServerID { throw ResonanceError.notConfigured }
        let _: EmptyResponse = try await fetch(.updatePlaylist(
            id: id,
            name: name,
            comment: comment,
            isPublic: isPublic,
            songIdsToAdd: songIdsToAdd,
            songIndexesToRemove: songIndexesToRemove
        ))
    }

    // MARK: - Start Library Scan

    func startScan() async throws {
        if fixtureCatalog != nil { return }
        let _: EmptyResponse = try await fetch(.startScan)
    }

    // MARK: - Navidrome Native API (JWT auth, used for file path lookups)

    private var nativeToken: String?

    /// Authenticate with navidrome's native API and get a JWT token.
    /// Reuses the same username/password as subsonic auth.
    private func authenticateNative() async throws -> String {
        if fixtureCatalog != nil { throw fixtureBlocked("native-auth") }
        if let token = nativeToken { return token }

        guard let server = activeServer, let auth = auth else {
            throw ResonanceError.notConfigured
        }
        guard PublicDemoConfiguration.allowsNetworkURL(server.url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
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

        recordTransportRequest()
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
        if fixtureCatalog != nil { throw fixtureBlocked("fetchSongFilePath") }
        let token = try await authenticateNative()

        guard let server = activeServer else {
            throw ResonanceError.notConfigured
        }
        guard PublicDemoConfiguration.allowsNetworkURL(server.url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }

        var components = URLComponents(url: server.url, resolvingAgainstBaseURL: true)!
        components.path = "/api/song/\(id)"

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "x-nd-authorization")

        recordTransportRequest()
        let (data, response) = try await session.data(for: request)

        // Token may have expired — retry once
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            self.nativeToken = nil
            let newToken = try await authenticateNative()
            request.setValue("Bearer \(newToken)", forHTTPHeaderField: "x-nd-authorization")
            recordTransportRequest()
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
