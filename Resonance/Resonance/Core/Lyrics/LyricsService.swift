import Foundation

enum LyricsLookupResult: Sendable {
    case found(CachedLyrics)
    case notFound
    case failed
}

actor LyricsService {
    enum SourceResult: Sendable {
        case found(CachedLyrics)
        case notFound
        case failed
    }

    typealias NavidromeSource = @Sendable (Song, UUID?) async -> SourceResult
    typealias LRCLibSource = @Sendable (Song) async -> SourceResult

    private let networkActor: NetworkActor
    private let cacheActor: CacheActor
    private let fixtureLyrics: [String: CachedLyrics]?
    private let fixtureState: ParityFixtureState?
    private let navidromeSource: NavidromeSource?
    private let lrclibSource: LRCLibSource?
    private let navidromeDeadline: Duration
    private let lrclibDeadline: Duration

    init(
        networkActor: NetworkActor,
        cacheActor: CacheActor,
        fixtureLyrics: [String: CachedLyrics]? = nil,
        fixtureState: ParityFixtureState? = nil,
        navidromeSource: NavidromeSource? = nil,
        lrclibSource: LRCLibSource? = nil,
        navidromeDeadline: Duration = .seconds(12),
        lrclibDeadline: Duration = .seconds(12)
    ) {
        self.networkActor = networkActor
        self.cacheActor = cacheActor
        self.fixtureLyrics = fixtureLyrics
        self.fixtureState = fixtureState
        self.navidromeSource = navidromeSource
        self.lrclibSource = lrclibSource
        self.navidromeDeadline = navidromeDeadline
        self.lrclibDeadline = lrclibDeadline
    }

    /// Convenience injection for atlas launch wiring. An empty lyrics map is a
    /// valid fixture, so the optional is intentionally populated in all cases.
    init(
        networkActor: NetworkActor,
        cacheActor: CacheActor,
        fixtureCatalog: ParityFixtureCatalog,
        fixtureState: ParityFixtureState? = nil
    ) {
        self.init(
            networkActor: networkActor,
            cacheActor: cacheActor,
            fixtureLyrics: fixtureCatalog.lyricsBySongID,
            fixtureState: fixtureState
        )
    }

    private var autoFetchEnabled: Bool {
        (UserDefaults.standard.object(forKey: "lyricsAutoFetch") as? Bool) ?? true
    }

    /// Called by PlaybackManager when song starts
    func prefetchLyrics(for song: Song) async {
        if fixtureLyrics != nil {
            _ = await getLyrics(for: song)
            return
        }
        guard autoFetchEnabled else { return }
        _ = await getLyrics(for: song)
    }

    /// Main entry point - returns CachedLyrics
    func getLyrics(for song: Song) async -> CachedLyrics? {
        guard case .found(let lyrics) = await lookupLyrics(for: song) else { return nil }
        return lyrics
    }

    /// Preserves the difference between a definitive empty result and a lookup
    /// failure so presentation code does not report network failures as no lyrics.
    func lookupLyrics(for song: Song) async -> LyricsLookupResult {
        if let fixtureLyrics {
            switch fixtureState {
            case .loading, .error:
                return .failed
            case .empty, .noLyrics:
                return .notFound
            case .plain:
                if let lyrics = fixtureLyrics[song.id] {
                    return .found(CachedLyrics(
                        songId: lyrics.songId,
                        source: lyrics.source,
                        syncedLyrics: nil,
                        plainLyrics: lyrics.plainLyrics ?? lyrics.syncedLyrics,
                        fetchedAt: lyrics.fetchedAt
                    ))
                }
                return .notFound
            case .synced:
                if let lyrics = fixtureLyrics[song.id] {
                    return .found(CachedLyrics(
                        songId: lyrics.songId,
                        source: lyrics.source,
                        syncedLyrics: lyrics.syncedLyrics ?? lyrics.plainLyrics,
                        plainLyrics: nil,
                        fetchedAt: lyrics.fetchedAt
                    ))
                }
                return .notFound
            case .playing, .paused, .selected, .loaded, nil:
                if let lyrics = fixtureLyrics[song.id], lyrics.preferredLyricsText != nil {
                    return .found(lyrics)
                }
                return .notFound
            }
        }

        guard !Task.isCancelled else { return .failed }

        // Snapshot the server before any cache/network suspension so lookups
        // never share an unscoped cache.
        let serverID = await networkActor.activeServer?.id
        guard !Task.isCancelled else { return .failed }

        // CacheActor removes expired negative entries according to its existing
        // TTL. A returned not-found value is therefore authoritative and must
        // short-circuit both network sources.
        if let cached = await cacheActor.getLyrics(for: song.id, serverId: serverID) {
            return cached.source == .notFound ? .notFound : .found(cached)
        }
        guard !Task.isCancelled else { return .failed }

        let injectedNavidromeSource = navidromeSource
        let navidromeResult = await sourceResult(before: navidromeDeadline) { [self] in
            if let injectedNavidromeSource {
                return await injectedNavidromeSource(song, serverID)
            }
            return await fetchFromNavidrome(song: song, expectedServerID: serverID)
        }
        guard !Task.isCancelled else { return .failed }
        guard await networkActor.activeServer?.id == serverID else { return .failed }
        if case .found(let lyrics) = navidromeResult {
            await cacheActor.cacheLyrics(lyrics, for: song.id, serverId: serverID)
            return .found(lyrics)
        }

        let injectedLRCLibSource = lrclibSource
        let lrclibResult = await sourceResult(before: lrclibDeadline) { [self] in
            if let injectedLRCLibSource {
                return await injectedLRCLibSource(song)
            }
            // The showcase build never sends library metadata to an external
            // lyrics service, so the fallback source is always a miss.
            return .notFound
        }
        guard !Task.isCancelled else { return .failed }
        guard await networkActor.activeServer?.id == serverID else { return .failed }
        if case .found(let lyrics) = lrclibResult {
            await cacheActor.cacheLyrics(lyrics, for: song.id, serverId: serverID)
            return .found(lyrics)
        }

        switch (navidromeResult, lrclibResult) {
        case (.notFound, .notFound):
            let notFound = CachedLyrics.notFound(songId: song.id)
            await cacheActor.cacheLyrics(notFound, for: song.id, serverId: serverID)
            return .notFound
        default:
            // An external miss cannot establish that a failed personal server
            // has no lyrics. Keep the result retryable and never negative-cache it.
            return .failed
        }
    }

    /// A lyrics-only deadline avoids inheriting the network actor's long resource
    /// timeout, which remains appropriate for library and media requests. The
    /// task-group scope waits for cooperative child teardown after cancellation;
    /// URLSession and the injected regression sources both honor cancellation.
    private func sourceResult(
        before deadline: Duration,
        operation: @escaping @Sendable () async -> SourceResult
    ) async -> SourceResult {
        guard !Task.isCancelled else { return .failed }

        return await withTaskGroup(of: SourceResult?.self) { group in
            group.addTask {
                // A parent canceled before this child starts must never invoke a
                // source merely because it was already enqueued in the group.
                guard !Task.isCancelled else { return nil }
                return await operation()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return nil
                }
                guard !Task.isCancelled else { return nil }
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed
        }
    }

    // MARK: - Navidrome Fetch

    private func fetchFromNavidrome(song: Song, expectedServerID: UUID?) async -> SourceResult {
        guard let expectedServerID else { return .notFound }
        do {
            guard let text = try await networkActor.fetchLyrics(
                artist: song.artist,
                title: song.title,
                expectedServerID: expectedServerID
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notFound
            }
            guard !Task.isCancelled else { return .failed }

            let isSynced = text.contains("[") && text.contains("]")
            return .found(CachedLyrics(
                songId: song.id,
                source: .navidrome,
                syncedLyrics: isSynced ? text : nil,
                plainLyrics: isSynced ? nil : text,
                fetchedAt: Date()
            ))
        } catch {
            return .failed
        }
    }
}
