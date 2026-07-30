import Foundation
import MediaPlayer

@MainActor
final class PlaybackManager: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var currentSourceSupportsSeeking = true
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackError: Error?

    private let audioActor: AudioActor
    private let networkActor: NetworkActor
    private let cacheActor: CacheActor
    private let queueManager: QueueManager
    private let databaseManager: DatabaseManager
    private let lyricsService: LyricsService
    private let nowPlayingService = NowPlayingService()
    private let notificationService = NotificationService()

    /// Active server ID for database operations (set by AppState on connect)
    var activeServerId: String = ""

    // MARK: - Navigation State

    var canGoPrevious: Bool {
        !queueManager.history.isEmpty || (currentSourceSupportsSeeking && currentTime > 3)
    }

    var canGoNext: Bool {
        queueManager.hasNext || repeatMode == .all
    }

    private var scrobbleTask: Task<Void, Never>?
    private var scrobbleThresholdReached = false
    private var currentPlayHistoryId: Int64?
    private var currentTrackedSongId: String?
    private var currentTrackedServerId: String?
    private var playbackStartedAt: Date?
    private var currentExternalStream: ExternalStreamSource?

    private struct ExternalStreamSource {
        let songID: String
        let url: URL
        let supportsSeeking: Bool
    }

    private struct HiddenPlaybackIds {
        let songs: Set<String>
        let albums: Set<String>
        let artists: Set<String>
    }

    init(audioActor: AudioActor, networkActor: NetworkActor, cacheActor: CacheActor, queueManager: QueueManager, databaseManager: DatabaseManager, lyricsService: LyricsService) {
        self.audioActor = audioActor
        self.networkActor = networkActor
        self.cacheActor = cacheActor
        self.queueManager = queueManager
        self.databaseManager = databaseManager
        self.lyricsService = lyricsService

        setupCallbacks()
    }

    private func setupCallbacks() {
        Task {
            await audioActor.setOnTimeUpdate { @Sendable [weak self] time in
                Task { @MainActor in
                    self?.currentTime = time
                    self?.checkScrobbleThreshold()
                }
            }

            await audioActor.setOnTrackFinished { @Sendable [weak self] in
                Task { @MainActor in
                    await self?.handleTrackFinished()
                }
            }
        }
    }

    // MARK: - Playback Control

    func play(song: Song, useCrossfade: Bool = false) async {
        guard isVisibleForPlayback(song) else { return }

        do {
            try await startPlayback(for: song, useCrossfade: useCrossfade)
        } catch {
            currentExternalStream = nil
            currentSourceSupportsSeeking = true
            playbackError = error
        }
    }

    func play(station: InternetRadioStation) async throws {
        guard let scheme = station.streamUrl.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResonanceError.unsupportedFormat(station.streamUrl.scheme ?? "station")
        }

        let radioSong = makeRadioSong(from: station)
        currentExternalStream = ExternalStreamSource(
            songID: radioSong.id,
            url: station.streamUrl,
            supportsSeeking: false
        )

        do {
            try await startPlayback(for: radioSong)
            queueManager.play([radioSong], startingAt: 0)
        } catch {
            currentExternalStream = nil
            currentSourceSupportsSeeking = true
            throw error
        }
    }

    /// Apply ReplayGain normalization based on user settings
    private func applyReplayGain(for song: Song) async {
        let mode = UserDefaults.standard.string(forKey: "replayGainMode") ?? "off"

        if mode == "off" {
            await audioActor.resetReplayGain()
            return
        }

        await audioActor.applyReplayGain(
            trackGain: song.replayGain?.trackGain,
            albumGain: song.replayGain?.albumGain,
            mode: mode
        )
    }

    /// Gets a local file URL for the song, either from cache or by downloading
    private func getLocalAudioURL(for song: Song) async throws -> URL {
        guard let server = await networkActor.activeServer else {
            throw ResonanceError.notConfigured
        }

        let quality = currentStreamingQuality

        // Check cache first (only for original quality - transcoded files vary by quality)
        if quality == .original,
           let cachedPath = await cacheActor.getAudioPath(for: song.id, serverId: server.id, suffix: song.suffix) {
            return cachedPath
        }

        // Download to cache
        let streamURL = try await networkActor.streamURL(for: song.id, quality: quality)
        let audioData = try await networkActor.downloadData(from: streamURL)

        // Only cache original quality files
        if quality == .original {
            let localPath = try await cacheActor.cacheAudio(audioData, for: song.id, serverId: server.id, suffix: song.suffix)
            return localPath
        } else {
            // For transcoded files, write to temp and don't cache
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(song.id)_\(quality.rawValue).mp3")
            try audioData.write(to: tempURL)
            return tempURL
        }
    }

    private var currentStreamingQuality: TranscodingQuality {
        let rawValue = UserDefaults.standard.string(forKey: "streamingQuality") ?? TranscodingQuality.original.rawValue
        return TranscodingQuality(rawValue: rawValue) ?? .original
    }

    func play(songs: [Song], startingAt index: Int = 0) async {
        let hiddenIds = hiddenPlaybackIds()
        let visibleIndexedSongs = songs.enumerated()
            .filter { isVisibleForPlayback($0.element, hiddenIds: hiddenIds) }
        guard !visibleIndexedSongs.isEmpty else { return }

        let visibleSongs = visibleIndexedSongs.map(\.element)
        let visibleStartIndex = visibleIndexedSongs.firstIndex { $0.offset >= index }
            ?? max(visibleSongs.count - 1, 0)

        queueManager.play(visibleSongs, startingAt: visibleStartIndex)
        if let song = queueManager.currentItem?.song {
            await play(song: song)
        }
    }

    func togglePlayPause() async {
        if isPlaying {
            await pause()
        } else {
            // Try to resume; if no audio is loaded, play the current song from queue
            do {
                try await audioActor.resume()
                isPlaying = true
                if let song = queueManager.currentItem?.song {
                    nowPlayingService.update(song: song, isPlaying: true, currentTime: currentTime, duration: duration)
                }
            } catch AudioActor.AudioError.noFileLoaded {
                // No audio loaded yet - start playing current song from queue
                if let song = queueManager.currentItem?.song {
                    await play(song: song)
                }
            } catch {
                playbackError = error
            }
        }
    }

    func pause() async {
        await audioActor.pause()
        isPlaying = false

        if let song = queueManager.currentItem?.song {
            nowPlayingService.update(song: song, isPlaying: false, currentTime: currentTime, duration: duration)
        }
    }

    func resume() async {
        do {
            try await audioActor.resume()
            isPlaying = true

            if let song = queueManager.currentItem?.song {
                nowPlayingService.update(song: song, isPlaying: true, currentTime: currentTime, duration: duration)
            }
        } catch AudioActor.AudioError.noFileLoaded {
            // Nothing to resume - try to play current song from queue
            if let song = queueManager.currentItem?.song {
                await play(song: song)
            }
        } catch {
            playbackError = error
            print("Resume error: \(error)")
        }
    }

    func stop() async {
        finalizePlayDuration()
        await audioActor.stop()
        isPlaying = false
        currentTime = 0
        duration = 0
        currentExternalStream = nil
        currentSourceSupportsSeeking = true

        nowPlayingService.clear()
    }

    /// Finalize duration_played for the current play history entry
    private func finalizePlayDuration() {
        let historyId = currentPlayHistoryId
        let songId = currentTrackedSongId
        let serverId = currentTrackedServerId

        defer {
            currentPlayHistoryId = nil
            currentTrackedSongId = nil
            currentTrackedServerId = nil
            playbackStartedAt = nil
        }

        let elapsed = Int(currentTime)
        guard elapsed > 0 else { return }

        if let historyId {
            try? databaseManager.updatePlayDuration(historyId: historyId, durationPlayed: elapsed)
        }

        if let songId, let serverId, !serverId.isEmpty {
            try? databaseManager.incrementWaitingRoomAudition(
                songId: songId,
                serverId: serverId,
                seconds: elapsed,
                lastPositionSeconds: elapsed
            )
        }
    }

    func seek(to time: TimeInterval) async {
        guard currentSourceSupportsSeeking else { return }
        await audioActor.seek(to: time)
        currentTime = time

        if let song = queueManager.currentItem?.song {
            nowPlayingService.update(song: song, isPlaying: isPlaying, currentTime: time, duration: duration)
        }
    }

    func setVolume(_ volume: Float) {
        Task {
            await audioActor.setVolume(volume)
        }
    }

    func next() async {
        let repeatAll = repeatMode == .all
        let hiddenIds = hiddenPlaybackIds()
        var remainingAttempts = max(queueManager.count, 1)

        while remainingAttempts > 0, let nextItem = queueManager.next(repeatAll: repeatAll) {
            remainingAttempts -= 1
            guard isVisibleForPlayback(nextItem.song, hiddenIds: hiddenIds) else { continue }
            await play(song: nextItem.song, useCrossfade: true)
            return
        }

        if currentExternalStream != nil {
            await stop()
        } else {
            // Queue exhausted — try autoplay
            let isAutoPlayEnabled = UserDefaults.standard.bool(forKey: "isAutoPlayEnabled")
            if isAutoPlayEnabled, let lastSong = queueManager.history.last?.song {
                await fetchAndPlayAutoPlay(seedSong: lastSong)
            } else {
                await stop()
            }
        }
    }

    func previous() async {
        // If past 3 seconds, restart current track
        if currentSourceSupportsSeeking && currentTime > 3 {
            await seek(to: 0)
            return
        }

        if let prevItem = queueManager.previous() {
            guard isVisibleForPlayback(prevItem.song) else { return }
            await play(song: prevItem.song)
        }
    }

    // MARK: - Repeat Mode

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Queue Operations

    func playNext(_ song: Song) {
        guard isVisibleForPlayback(song) else { return }

        queueManager.playNext(song)
        // If queue was empty, start playback
        if queueManager.needsPlaybackStart {
            queueManager.needsPlaybackStart = false
            Task {
                await play(song: song)
            }
        }
    }

    func addToQueue(_ song: Song) {
        guard isVisibleForPlayback(song) else { return }

        queueManager.addToQueue(song)
    }

    func addToQueue(_ songs: [Song]) {
        let hiddenIds = hiddenPlaybackIds()
        let visibleSongs = songs.filter { isVisibleForPlayback($0, hiddenIds: hiddenIds) }
        guard !visibleSongs.isEmpty else { return }

        queueManager.addToQueue(visibleSongs)
    }

    func playNow(_ song: Song) async {
        guard isVisibleForPlayback(song) else { return }

        if queueManager.isEmpty {
            // Queue is empty - set up fresh queue with this song
            queueManager.play([song], startingAt: 0)
        } else {
            // Insert after current and advance to it
            queueManager.playNext(song)
            _ = queueManager.next()
        }
        await play(song: song)
    }

    // MARK: - AutoPlay

    private func fetchAndPlayAutoPlay(seedSong: Song) async {
        do {
            let hiddenIds = hiddenPlaybackIds()
            let similarSongs = try await networkActor.getSimilarSongs(id: seedSong.id, count: 20)
                .filter { isVisibleForPlayback($0, hiddenIds: hiddenIds) }
            guard !similarSongs.isEmpty else {
                await stop()
                return
            }

            queueManager.setAutoPlayItems(similarSongs)

            // Now try next() again — it will pull from autoPlayItems
            if let nextItem = queueManager.next() {
                await play(song: nextItem.song, useCrossfade: true)
            } else {
                await stop()
            }
        } catch {
            print("AutoPlay fetch failed: \(error)")
            await stop()
        }
    }

    // MARK: - Private

    private func hiddenPlaybackIds() -> HiddenPlaybackIds {
        guard !activeServerId.isEmpty else {
            return HiddenPlaybackIds(songs: [], albums: [], artists: [])
        }

        return HiddenPlaybackIds(
            songs: (try? databaseManager.loadHiddenIds(type: "song", serverId: activeServerId)) ?? [],
            albums: (try? databaseManager.loadHiddenIds(type: "album", serverId: activeServerId)) ?? [],
            artists: (try? databaseManager.loadHiddenIds(type: "artist", serverId: activeServerId)) ?? []
        )
    }

    private func isVisibleForPlayback(_ song: Song) -> Bool {
        isVisibleForPlayback(song, hiddenIds: hiddenPlaybackIds())
    }

    private func isVisibleForPlayback(_ song: Song, hiddenIds: HiddenPlaybackIds) -> Bool {
        !hiddenIds.songs.contains(song.id) &&
            !hiddenIds.albums.contains(song.albumId) &&
            !hiddenIds.artists.contains(song.artistId)
    }

    private func handleTrackFinished() async {
        // Scrobble if threshold was reached
        if scrobbleThresholdReached, let song = queueManager.currentItem?.song {
            await scrobble(song: song)
        }

        // Handle repeat one mode - replay current track
        if repeatMode == .one, let song = queueManager.currentItem?.song {
            await play(song: song)
            return
        }

        // Play next track
        await next()
    }

    private func checkScrobbleThreshold() {
        guard !scrobbleThresholdReached, currentExternalStream == nil, duration > 0 else { return }

        // Scrobble at 50% or 4 minutes, whichever first
        let threshold = min(duration * 0.5, 240)
        if currentTime >= threshold {
            scrobbleThresholdReached = true
        }
    }

    private func scrobble(song: Song) async {
        do {
            try await networkActor.scrobble(id: song.id, time: Date(), submission: true)
        } catch {
            // Scrobble failures are non-critical, just log
            print("Scrobble failed for \(song.title): \(error)")
        }
    }

    // MARK: - Notifications

    private func postTrackNotification(for song: Song) async {
        // Get first lyrics line if showLyricsInNotifications is enabled
        var firstLyricsLine: String? = nil
        if UserDefaults.standard.bool(forKey: "showLyricsInNotifications") {
            if let cachedLyrics = await lyricsService.getLyrics(for: song) {
                firstLyricsLine = extractFirstLyricsLine(from: cachedLyrics)
            }
        }

        let result = await notificationService.postTrackChange(song: song, firstLyricsLine: firstLyricsLine)
        if case .failure(let error) = result {
            // Non-critical, just log
            print("Notification failed for \(song.title): \(error)")
        }
    }

    private func extractFirstLyricsLine(from cached: CachedLyrics) -> String? {
        // Prefer synced lyrics, fall back to plain
        let text = cached.syncedLyrics ?? cached.plainLyrics
        guard let text = text else { return nil }

        // For synced lyrics, strip timestamp markers like [00:12.34]
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            var cleanLine = line.trimmingCharacters(in: .whitespaces)

            // Strip LRC timestamps: [00:12.34] or [mm:ss.xx]
            while cleanLine.hasPrefix("[") {
                if let closeBracket = cleanLine.firstIndex(of: "]") {
                    cleanLine = String(cleanLine[cleanLine.index(after: closeBracket)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    break
                }
            }

            // Skip empty lines and metadata lines
            if !cleanLine.isEmpty && !cleanLine.hasPrefix("[") {
                return cleanLine
            }
        }

        return nil
    }

    private func startPlayback(for song: Song, useCrossfade: Bool = false) async throws {
        finalizePlayDuration()

        playbackError = nil
        isBuffering = true
        defer { isBuffering = false }

        let playbackURL = try await resolvePlaybackURL(for: song)

        let crossfadeDuration = await audioActor.getCrossfadeDuration()
        let shouldCrossfade = useCrossfade && currentSourceSupportsSeeking && isPlaying && crossfadeDuration > 0
        if shouldCrossfade {
            try await audioActor.crossfadeTo(url: playbackURL)
        } else {
            try await audioActor.play(url: playbackURL)
        }

        isPlaying = true
        currentTime = 0

        let loadedDuration = await audioActor.getDuration()
        duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
        if duration == 0 {
            currentSourceSupportsSeeking = false
        }

        scrobbleThresholdReached = currentExternalStream != nil

        if currentExternalStream == nil {
            await applyReplayGain(for: song)
        } else {
            await audioActor.resetReplayGain()
        }

        nowPlayingService.update(song: song, isPlaying: true, currentTime: 0, duration: duration)

        if currentExternalStream == nil {
            currentPlayHistoryId = try? databaseManager.recordPlay(song: song, serverId: activeServerId)
            currentTrackedSongId = song.id
            currentTrackedServerId = activeServerId
            playbackStartedAt = Date()

            Task {
                await lyricsService.prefetchLyrics(for: song)
            }

            Task {
                await postTrackNotification(for: song)
            }
        }
    }

    private func resolvePlaybackURL(for song: Song) async throws -> URL {
        if let currentExternalStream, currentExternalStream.songID == song.id {
            currentSourceSupportsSeeking = currentExternalStream.supportsSeeking
            return currentExternalStream.url
        }

        currentExternalStream = nil
        currentSourceSupportsSeeking = true
        return try await getLocalAudioURL(for: song)
    }

    private func makeRadioSong(from station: InternetRadioStation) -> Song {
        let displayHost = station.homePageUrl?.host ?? station.streamUrl.host ?? "Live Stream"
        let suffix = station.streamUrl.pathExtension.isEmpty ? "stream" : station.streamUrl.pathExtension

        return Song(
            id: "radio:\(station.id)",
            title: station.name,
            album: "Internet Radio",
            albumId: "",
            artist: displayHost,
            artistId: "",
            track: nil,
            discNumber: nil,
            year: nil,
            genre: "Radio",
            duration: 0,
            bitRate: nil,
            contentType: "audio/aac",
            suffix: suffix,
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )
    }
}
