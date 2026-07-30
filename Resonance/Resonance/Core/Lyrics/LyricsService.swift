import Foundation

actor LyricsService {
    private let networkActor: NetworkActor
    private let cacheActor: CacheActor
    private let session: URLSession

    init(networkActor: NetworkActor, cacheActor: CacheActor) {
        self.networkActor = networkActor
        self.cacheActor = cacheActor
        self.session = URLSession.shared
    }

    private var autoFetchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "lyricsAutoFetch")
    }

    /// Called by PlaybackManager when song starts
    func prefetchLyrics(for song: Song) async {
        guard autoFetchEnabled else { return }
        _ = await getLyrics(for: song)
    }

    /// Main entry point - returns CachedLyrics
    func getLyrics(for song: Song) async -> CachedLyrics? {
        // 1. Check cache
        if let cached = await cacheActor.getLyrics(for: song.id), cached.source != .notFound {
            return cached
        }

        // 2. Try Navidrome server first
        if let lyrics = await fetchFromNavidrome(song: song) {
            await cacheActor.cacheLyrics(lyrics, for: song.id)
            return lyrics
        }

        // 3. Try LRCLIB
        if let lyrics = await fetchFromLRCLib(song: song) {
            await cacheActor.cacheLyrics(lyrics, for: song.id)
            return lyrics
        }

        // 4. Cache "not found" to avoid repeated lookups
        let notFound = CachedLyrics.notFound(songId: song.id)
        await cacheActor.cacheLyrics(notFound, for: song.id)
        return nil
    }

    // MARK: - Navidrome Fetch

    private func fetchFromNavidrome(song: Song) async -> CachedLyrics? {
        do {
            guard let text = try await networkActor.fetchLyrics(
                artist: song.artist,
                title: song.title
            ), !text.isEmpty else {
                return nil
            }

            let isSynced = text.contains("[") && text.contains("]")
            return CachedLyrics(
                songId: song.id,
                source: .navidrome,
                syncedLyrics: isSynced ? text : nil,
                plainLyrics: isSynced ? nil : text,
                fetchedAt: Date()
            )
        } catch {
            return nil
        }
    }

    // MARK: - LRCLIB Fetch

    private func fetchFromLRCLib(song: Song) async -> CachedLyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "artist_name", value: song.artist),
            URLQueryItem(name: "album_name", value: song.album),
            URLQueryItem(name: "duration", value: String(song.duration))
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Resonance/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let lrcResponse = try JSONDecoder().decode(LRCLibResponse.self, from: data)

            if lrcResponse.instrumental == true {
                return nil
            }

            guard lrcResponse.syncedLyrics != nil || lrcResponse.plainLyrics != nil else {
                return nil
            }

            return CachedLyrics(
                songId: song.id,
                source: .lrclib,
                syncedLyrics: lrcResponse.syncedLyrics,
                plainLyrics: lrcResponse.plainLyrics,
                fetchedAt: Date()
            )
        } catch {
            return nil
        }
    }
}
