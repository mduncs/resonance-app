import Foundation

actor LyricsService {
    private let networkActor: NetworkActor
    private let cacheActor: CacheActor

    init(networkActor: NetworkActor, cacheActor: CacheActor) {
        self.networkActor = networkActor
        self.cacheActor = cacheActor
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

        // 3. Cache "not found" to avoid repeated lookups. The showcase build
        // never sends library metadata to an external lyrics service.
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

}
