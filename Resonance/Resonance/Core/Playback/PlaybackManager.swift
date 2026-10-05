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
    var activeServerId: String = "" {
        didSet {
            if activeServerId != oldValue { invalidateForServerChange() }
        }
    }

    /// Invalidates pending AutoPlay discovery when a newer transport intent arrives.
    /// This does not serialize the separate audio-loading pipeline.
    private var playbackIntentGeneration: UInt64 = 0 {
        didSet {
            if restoreStartTask != nil {
                restoreStartTask?.cancel()
                isBuffering = false
            }
        }
    }
    private var restoreStartTask: Task<Void, Never>?
    private var restoreStartID: UUID?
    private var stagedRestore: StagedRestore?
    private var audioOwnershipID: UUID?
    /// Separates overlapping position requests without turning seeks into new
    /// playback intents (which also coordinate launch restoration).
    private var seekGeneration: UInt64 = 0

    struct RestoreTicket: Equatable {
        let intent: UInt64
        let occurrence: UUID
        let serverID: String
    }
    private struct StagedRestore {
        let occurrence: UUID
        let serverID: String
        var position: TimeInterval
    }

    func invalidateRestoration() {
        playbackIntentGeneration &+= 1
        stagedRestore = nil
    }

    /// Synchronous identity boundary; cleanup only owns the displaced audio request.
    func invalidateForServerChange() {
        invalidateRestoration()
        // Identity is assigned before the fixture seeds PlaybackManager's flag.
        guard !DeterministicCaptureFixture.isEnabled else { return }
        finalizePlayDuration()
        if let id = audioOwnershipID {
            let audio = audioActor
            Task { await audio.cancelRestoration(id: id) }
        }
        audioOwnershipID = nil
        currentExternalStream = nil
        currentSourceSupportsSeeking = true
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        nowPlayingService.clear()
    }

    /// No startPlayback/audio/service calls: this is genuinely paused restoration.
    func stagePausedRestore(songs: [Song], startingAt index: Int, position: TimeInterval,
                            serverID: String) -> RestoreTicket? {
        guard !deterministicCaptureMode, queueManager.isEmpty, !songs.isEmpty,
              serverID == activeServerId, !serverID.isEmpty else { return nil }
        queueManager.play(songs, startingAt: max(0, min(index, songs.count - 1)))
        guard let item = queueManager.currentItem else { return nil }
        duration = max(0, TimeInterval(item.song.duration))
        currentTime = position.isFinite ? max(0, min(position, duration)) : 0
        isPlaying = false
        isBuffering = false
        currentSourceSupportsSeeking = true
        stagedRestore = StagedRestore(occurrence: item.id, serverID: serverID, position: currentTime)
        return RestoreTicket(intent: playbackIntentGeneration, occurrence: item.id, serverID: serverID)
    }

    func resumeRestoredIfCurrent(ticket: RestoreTicket) async {
        guard ticket.intent == playbackIntentGeneration,
              ticket.serverID == activeServerId,
              ticket.occurrence == queueManager.currentItem?.id,
              stagedRestore?.occurrence == ticket.occurrence else { return }
        await resume()
    }

    private func startStagedRestoreIfNeeded() async -> Bool {
        guard let staged = stagedRestore else { return false }
        guard staged.serverID == activeServerId,
              let item = queueManager.currentItem, item.id == staged.occurrence else {
            stagedRestore = nil
            return false
        }
        let intent = playbackIntentGeneration
        let audioRestoreID = UUID()
        let audio = audioActor
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    try await self.startPlayback(for: item.song, initialPosition: staged.position,
                        restoration: RestoreTicket(intent: intent, occurrence: item.id, serverID: staged.serverID),
                        audioRestorationID: audioRestoreID)
                } onCancel: {
                    Task { await audio.cancelRestoration(id: audioRestoreID) }
                }
                if self.playbackIntentGeneration == intent {
                    self.stagedRestore = nil
                }
            } catch is CancellationError {
                await audio.cancelRestoration(id: audioRestoreID)
                // Keep the staged position on pause; replacement/server guards reject it.
            } catch {
                if self.playbackIntentGeneration == intent { self.playbackError = error }
            }
        }
        restoreStartID = audioRestoreID
        restoreStartTask = task
        await task.value
        if restoreStartID == audioRestoreID {
            restoreStartTask = nil
            restoreStartID = nil
        }
        return true
    }

    private func checkRestoration(_ ticket: RestoreTicket?) throws {
        guard let ticket else { return }
        try Task.checkCancellation()
        guard playbackIntentGeneration == ticket.intent, activeServerId == ticket.serverID,
              queueManager.currentItem?.id == ticket.occurrence else { throw CancellationError() }
    }

    // MARK: - Navigation State

    var canGoPrevious: Bool {
        queueManager.hasPrevious || (currentSourceSupportsSeeking && currentTime > 3)
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
    private var deterministicCaptureMode = false

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

    /// Seeds published playback state for the launch-only capture fixture.
    /// This intentionally bypasses `startPlayback(for:)`: no URL resolution,
    /// cache lookup, network request, or AVPlayer item is created.
    func installDeterministicCaptureFixture(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        supportsSeeking: Bool
    ) {
        deterministicCaptureMode = true
        scrobbleTask?.cancel()
        currentExternalStream = nil
        playbackError = nil
        isBuffering = false
        currentSourceSupportsSeeking = supportsSeeking
        self.duration = max(0, duration)
        self.currentTime = max(0, min(currentTime, self.duration))
        self.isPlaying = isPlaying
    }

    // MARK: - Playback Control

    func play(song: Song, useCrossfade: Bool = false) async {
        invalidateRestoration()
        if deterministicCaptureMode {
            isBuffering = false
            currentTime = 0
            duration = max(0, TimeInterval(song.duration))
            isPlaying = true
            return
        }

        guard isVisibleForPlayback(song) else { return }
        let intent = playbackIntentGeneration
        do {
            try await startPlayback(for: song, useCrossfade: useCrossfade)
        } catch is CancellationError {
            return
        } catch {
            guard intent == playbackIntentGeneration else { return }
            currentExternalStream = nil
            currentSourceSupportsSeeking = true
            playbackError = error
        }
    }

    func play(station: InternetRadioStation) async throws {
        invalidateRestoration()
        if deterministicCaptureMode {
            isBuffering = false
            isPlaying = true
            return
        }

        guard let scheme = station.streamUrl.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResonanceError.unsupportedFormat(station.streamUrl.scheme ?? "station")
        }
        // Station URLs come from the server and can point anywhere; the
        // showcase build only plays streams from its loopback demo server.
        guard PublicDemoConfiguration.allowsNetworkURL(station.streamUrl) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }

        let radioSong = makeRadioSong(from: station)
        currentExternalStream = ExternalStreamSource(
            songID: radioSong.id,
            url: station.streamUrl,
            supportsSeeking: false
        )

        let intent = playbackIntentGeneration
        do {
            try await startPlayback(for: radioSong)
            queueManager.play([radioSong], startingAt: 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard intent == playbackIntentGeneration else { throw CancellationError() }
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
        playbackIntentGeneration &+= 1
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
        playbackIntentGeneration &+= 1
        if deterministicCaptureMode {
            isPlaying.toggle()
            return
        }

        if isPlaying {
            await pause()
        } else {
            if await startStagedRestoreIfNeeded() { return }
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
        playbackIntentGeneration &+= 1
        isBuffering = false
        if deterministicCaptureMode {
            isPlaying = false
            return
        }

        await audioActor.pause()
        isPlaying = false

        if let song = queueManager.currentItem?.song {
            nowPlayingService.update(song: song, isPlaying: false, currentTime: currentTime, duration: duration)
        }
    }

    func resume() async {
        playbackIntentGeneration &+= 1
        if deterministicCaptureMode {
            isPlaying = true
            return
        }
        if await startStagedRestoreIfNeeded() { return }

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
        invalidateRestoration()
        if deterministicCaptureMode {
            scrobbleTask?.cancel()
            isPlaying = false
            currentTime = 0
            duration = 0
            currentExternalStream = nil
            currentSourceSupportsSeeking = true
            return
        }

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
        await seek(to: time, performAudioSeek: { [audioActor] target, ownershipID, requestGeneration in
            await audioActor.seek(to: target, expecting: ownershipID, requestGeneration: requestGeneration)
        })
    }

    /// The injected operation keeps async completion ownership testable without
    /// constructing or mutating a live AVPlayer.
    func seek(to time: TimeInterval,
              performAudioSeek: @MainActor (TimeInterval, UUID?, UInt64) async -> Bool) async {
        guard currentSourceSupportsSeeking else { return }

        // Every newer request supersedes an older completion, including a
        // staged/deterministic seek or a request made after the queue emptied.
        seekGeneration &+= 1
        let requestGeneration = seekGeneration
        let seekDuration = duration.isFinite ? max(0, duration) : 0
        let target = time.isFinite ? min(seekDuration, max(0, time)) : 0

        if var staged = stagedRestore, staged.serverID == activeServerId,
           staged.occurrence == queueManager.currentItem?.id {
            playbackIntentGeneration &+= 1
            staged.position = target
            stagedRestore = staged
            currentTime = staged.position
            return
        }

        if deterministicCaptureMode {
            currentTime = target
            return
        }

        guard let item = queueManager.currentItem else { return }
        let intent = playbackIntentGeneration
        let serverID = activeServerId
        let occurrenceID = item.id
        let song = item.song
        let ownershipID = audioOwnershipID

        let didSeek = await performAudioSeek(target, ownershipID, requestGeneration)

        // AudioActor and AVPlayer calls are async/reentrant. Do not let an old
        // completion publish its target against a replacement queue item,
        // server, transport intent, or newer seek request.
        guard didSeek,
              let currentItem = queueManager.currentItem,
              seekGeneration == requestGeneration,
              playbackIntentGeneration == intent,
              activeServerId == serverID,
              currentItem.id == occurrenceID,
              currentItem.song.id == song.id,
              currentSourceSupportsSeeking else { return }

        currentTime = target
        nowPlayingService.update(song: currentItem.song, isPlaying: isPlaying, currentTime: target, duration: duration)
    }

    func setVolume(_ volume: Float) {
        Task {
            await audioActor.setVolume(volume)
        }
    }

    func next() async {
        playbackIntentGeneration &+= 1
        if deterministicCaptureMode {
            if let nextItem = queueManager.next(repeatAll: repeatMode == .all) {
                currentTime = 0
                duration = TimeInterval(nextItem.song.duration)
            } else {
                isPlaying = false
                currentTime = 0
                duration = 0
            }
            return
        }

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
        playbackIntentGeneration &+= 1
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
        playbackIntentGeneration &+= 1
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

    /// Also invalidates off→on preference changes while discovery is suspended.
    func invalidatePendingAutoPlay() {
        playbackIntentGeneration &+= 1
    }

    private func fetchAndPlayAutoPlay(seedSong: Song) async {
        let generation = playbackIntentGeneration
        let serverId = activeServerId
        let seedOccurrenceId = queueManager.history.last?.id

        // Queue item identity distinguishes repeated plays of the same song.
        // Check errors as well as successful responses: an obsolete failure must
        // never stop playback started while discovery was awaiting the server.
        func requestIsCurrent() -> Bool {
            !Task.isCancelled
                && playbackIntentGeneration == generation
                && !serverId.isEmpty
                && activeServerId == serverId
                && seedOccurrenceId != nil
                && queueManager.history.last?.id == seedOccurrenceId
                && queueManager.currentItem == nil
                && !queueManager.hasNext
                && UserDefaults.standard.bool(forKey: "isAutoPlayEnabled")
        }

        guard requestIsCurrent(), let expectedServerID = UUID(uuidString: serverId) else { return }
        do {
            let response = try await networkActor.getSimilarSongs(
                id: seedSong.id, count: 20, expectedServerID: expectedServerID
            )
            guard requestIsCurrent() else { return }

            // Curation can change while the request is suspended.
            let hiddenIds = hiddenPlaybackIds()
            let similarSongs = response.filter { isVisibleForPlayback($0, hiddenIds: hiddenIds) }
            guard !similarSongs.isEmpty else {
                await stop()
                return
            }

            queueManager.setAutoPlayItems(similarSongs)

            // Pull from the existing sectioned queue, retaining its deduplication
            // and manual/base/autoplay ordering semantics.
            if let nextItem = queueManager.next() {
                await play(song: nextItem.song, useCrossfade: true)
            } else {
                await stop()
            }
        } catch {
            guard !(error is CancellationError), requestIsCurrent() else { return }
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
        guard !deterministicCaptureMode else { return }

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

    private func startPlayback(for song: Song, useCrossfade: Bool = false,
                               initialPosition: TimeInterval = 0,
                               restoration: RestoreTicket? = nil,
                               audioRestorationID: UUID? = nil) async throws {
        let intent = playbackIntentGeneration
        let serverID = activeServerId
        let ownership = audioRestorationID ?? UUID()
        audioOwnershipID = ownership
        func checkCurrentIntent() throws {
            try Task.checkCancellation()
            guard intent == playbackIntentGeneration, serverID == activeServerId else { throw CancellationError() }
            try checkRestoration(restoration)
        }
        try checkCurrentIntent()
        finalizePlayDuration()

        playbackError = nil
        isBuffering = true
        defer {
            if intent == playbackIntentGeneration, serverID == activeServerId { isBuffering = false }
        }

        let playbackURL = try await resolvePlaybackURL(for: song)
        try checkCurrentIntent()

        let crossfadeDuration = await audioActor.getCrossfadeDuration()
        try checkCurrentIntent()
        let shouldCrossfade = useCrossfade && currentSourceSupportsSeeking && isPlaying && crossfadeDuration > 0
        if shouldCrossfade {
            try await audioActor.crossfadeTo(url: playbackURL, ownershipID: ownership)
        } else {
            try await audioActor.play(url: playbackURL, initialPosition: initialPosition, restorationID: ownership)
        }
        try checkCurrentIntent()

        let loadedDuration = await audioActor.getDuration()
        try checkCurrentIntent()
        isPlaying = true
        currentTime = max(0, min(initialPosition, loadedDuration))
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

        try checkCurrentIntent()
        nowPlayingService.update(song: song, isPlaying: true, currentTime: currentTime, duration: duration)

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
