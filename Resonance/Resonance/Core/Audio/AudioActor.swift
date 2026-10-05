import AVFoundation
import Combine

actor AudioActor {
    private var loadGeneration: UInt64 = 0
    private var currentRestorationID: UUID?
    /// Ownership is eligible for seeking only while its item is the active player.
    /// A crossfade records the incoming restoration owner before the player swap,
    /// so this remains nil during that transition.
    private var activeSeekOwnershipID: UUID?
    private var latestSeekRequestGeneration: UInt64 = 0
    // Cancellation can arrive while URL resolution precedes actor registration.
    private var cancelledOwnershipIDs = Set<UUID>()
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    /// Runtime evidence for the parity fixture's no-live-playback contract.
    /// This increments at the two points where Resonance creates an
    /// `AVPlayerItem`; a settled fixture launch must report zero.
    private var playerItemCreationCount = 0

    /// Read-only capture audit. Normal playback behavior is unchanged.
    func auditPlayerItemCreationCount() -> Int {
        playerItemCreationCount
    }
    private var timeObserver: Any?

    // Crossfade support
    private var crossfadePlayer: AVPlayer?
    private var crossfadeDuration: TimeInterval = 0
    private var isCrossfading = false
    private var crossfadePreparedDuration: TimeInterval?
    private var crossfadeTask: Task<Void, Never>?

    private var isPlaying = false
    private var duration: TimeInterval = 0
    private var userVolume: Float = 1.0
    private var replayGainMultiplier: Float = 1.0

    // Callbacks
    private var onTimeUpdate: (@Sendable (TimeInterval) -> Void)?
    private var onTrackFinished: (@Sendable () -> Void)?
    private var finishedObserver: NSObjectProtocol?
    private var crossfadeFinishedObserver: NSObjectProtocol?

    init() {}

    // MARK: - Public API

    func play(url: URL, initialPosition: TimeInterval = 0, restorationID: UUID? = nil) async throws {
        try Task.checkCancellation()
        if let restorationID, cancelledOwnershipIDs.contains(restorationID) { throw CancellationError() }
        loadGeneration &+= 1
        let generation = loadGeneration
        currentRestorationID = restorationID
        activeSeekOwnershipID = nil
        latestSeekRequestGeneration = 0
        stopCrossfade()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        isPlaying = false

        let asset = AVURLAsset(url: url)
        playerItemCreationCount += 1
        let item = AVPlayerItem(asset: asset)
        let durationCMTime = try? await asset.load(.duration)
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        let loadedDuration = durationCMTime.map(CMTimeGetSeconds) ?? 0
        let safeDuration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
        let candidate = AVPlayer(playerItem: item)
        candidate.allowsExternalPlayback = true
        let position = initialPosition.isFinite ? max(0, min(initialPosition, safeDuration)) : 0
        if position > 0 {
            await candidate.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Cancellation cleanup is candidate-local; never pause/clear a newer player.
        guard !Task.isCancelled, generation == loadGeneration else {
            candidate.pause()
            candidate.replaceCurrentItem(with: nil)
            throw CancellationError()
        }
        playerItem = item
        player = candidate
        duration = safeDuration
        activeSeekOwnershipID = restorationID
        let itemIdentity = ObjectIdentifier(item)
        finishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { await self?.handleTrackFinished(itemIdentity: itemIdentity) }
        }
        applyVolume()
        candidate.play()
        isPlaying = true
        startTimeTracking()
    }

    /// An old cancellation must never pause a replacement player.
    func cancelRestoration(id: UUID) {
        cancelledOwnershipIDs.insert(id)
        guard currentRestorationID == id else { return }
        loadGeneration &+= 1
        currentRestorationID = nil
        activeSeekOwnershipID = nil
        latestSeekRequestGeneration = 0
        stopCrossfade()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        isPlaying = false
    }

    func pause() {
        loadGeneration &+= 1
        if isCrossfading {
            crossfadeTask?.cancel()
            crossfadeTask = nil
            if crossfadePlayer?.currentItem != nil, let incomingDuration = crossfadePreparedDuration {
                // Queue/PlaybackManager already name the incoming track. Promote it
                // paused; never resume the outgoing track under the incoming title.
                crossfadePlayer?.pause()
                completeCrossfade(newDuration: incomingDuration)
            } else {
                // Incoming preparation has not produced an item. Drop the outgoing
                // item so resume's noFileLoaded path resolves the actual queued song.
                stopCrossfade()
                removeObservers()
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                player = nil
                playerItem = nil
                activeSeekOwnershipID = nil
                latestSeekRequestGeneration = 0
            }
        }
        player?.pause()
        isPlaying = false
    }

    func resume() throws {
        guard playerItem != nil else {
            throw AudioError.noFileLoaded
        }
        player?.play()
        isPlaying = true
        startTimeTracking()
    }

    enum AudioError: Error {
        case noFileLoaded
    }

    func stop() {
        currentRestorationID = nil
        activeSeekOwnershipID = nil
        latestSeekRequestGeneration = 0
        loadGeneration &+= 1
        stopCrossfade()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        isPlaying = false
    }

    /// A seek carries both the manager's playback owner and monotonic request
    /// generation. Validate before touching AVPlayer so delayed actor messages
    /// cannot seek a replacement item or let an older overlapping request win.
    func seek(to time: TimeInterval, expecting ownershipID: UUID?, requestGeneration: UInt64) async -> Bool {
        guard let ownershipID,
              activeSeekOwnershipID == ownershipID,
              requestGeneration > latestSeekRequestGeneration,
              let expectedPlayer = player,
              let expectedItem = playerItem else { return false }

        latestSeekRequestGeneration = requestGeneration
        let clampedTime = time.isFinite ? max(0, min(time, duration)) : 0
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        let finished = await expectedPlayer.seek(
            to: cmTime,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity
        )
        guard finished else { return false }

        // AVPlayer seek is async and the actor is reentrant while it runs.
        // Report completion only while the same item/request still owns playback.
        return activeSeekOwnershipID == ownershipID
            && latestSeekRequestGeneration == requestGeneration
            && player === expectedPlayer
            && playerItem === expectedItem
    }

    func setVolume(_ vol: Float) {
        userVolume = vol
        applyVolume()
    }

    func getVolume() -> Float {
        userVolume
    }

    /// Apply ReplayGain normalization for the current track
    /// - Parameters:
    ///   - trackGain: Track gain in dB (from ReplayGain metadata)
    ///   - albumGain: Album gain in dB (from ReplayGain metadata)
    ///   - mode: "off", "track", or "album"
    func applyReplayGain(trackGain: Float?, albumGain: Float?, mode: String) {
        replayGainMultiplier = calculateReplayGainMultiplier(
            trackGain: trackGain,
            albumGain: albumGain,
            mode: mode
        )
        applyVolume()
    }

    /// Reset ReplayGain to unity (1.0) - use when track has no RG data or mode is off
    func resetReplayGain() {
        replayGainMultiplier = 1.0
        applyVolume()
    }

    // MARK: - Volume Helpers

    private func applyVolume() {
        // Combine user volume with ReplayGain, clamped to prevent clipping
        let effectiveVolume = min(userVolume * replayGainMultiplier, 1.0)
        player?.volume = effectiveVolume
    }

    /// Calculate volume multiplier from ReplayGain values
    /// Formula: 10^((gain + preamp) / 20)
    /// Preamp of -6dB provides headroom to prevent clipping
    private func calculateReplayGainMultiplier(trackGain: Float?, albumGain: Float?, mode: String) -> Float {
        let preamp: Float = -6.0  // Prevent clipping on loud tracks

        let gain: Float
        switch mode {
        case "track":
            gain = trackGain ?? 0
        case "album":
            // Prefer album gain, fall back to track gain
            gain = albumGain ?? trackGain ?? 0
        default:
            // "off" or unknown - no normalization
            return 1.0
        }

        // No RG data available
        if trackGain == nil && albumGain == nil {
            return 1.0
        }

        return pow(10, (gain + preamp) / 20)
    }

    func getCurrentTime() -> TimeInterval {
        guard let time = player?.currentTime() else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return 0 }
        return max(0, min(seconds, duration))
    }

    func getDuration() -> TimeInterval {
        duration
    }

    func getIsPlaying() -> Bool {
        isPlaying
    }

    // MARK: - Crossfade

    func setCrossfadeDuration(_ newDuration: TimeInterval) {
        crossfadeDuration = newDuration
    }

    func getCrossfadeDuration() -> TimeInterval {
        crossfadeDuration
    }

    /// Crossfade to a new track with volume interpolation
    func crossfadeTo(url: URL, ownershipID: UUID? = nil) async throws {
        try Task.checkCancellation()
        if let ownershipID, cancelledOwnershipIDs.contains(ownershipID) { throw CancellationError() }
        loadGeneration &+= 1
        let generation = loadGeneration
        currentRestorationID = ownershipID
        activeSeekOwnershipID = nil
        latestSeekRequestGeneration = 0
        // If crossfade is disabled or no current track, just play normally
        guard crossfadeDuration > 0, isPlaying, player != nil else {
            try await play(url: url, restorationID: ownershipID)
            return
        }

        isCrossfading = true
        crossfadePreparedDuration = nil

        // Cancel any existing crossfade
        crossfadeTask?.cancel()

        // Create new player for incoming track
        crossfadePlayer = AVPlayer()
        let asset = AVURLAsset(url: url)
        playerItemCreationCount += 1
        let item = AVPlayerItem(asset: asset)

        let newDuration = try await asset.load(.duration)
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        let rawDuration = CMTimeGetSeconds(newDuration)
        let newDurationSeconds = rawDuration.isFinite ? max(0, rawDuration) : 0
        crossfadePreparedDuration = newDurationSeconds

        crossfadePlayer?.replaceCurrentItem(with: item)
        crossfadePlayer?.volume = 0  // Start silent

        // Register end-of-track observer IMMEDIATELY so we don't miss the notification
        let incomingIdentity = ObjectIdentifier(item)
        crossfadeFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleTrackFinished(itemIdentity: incomingIdentity) }
        }

        // Start playing the new track
        crossfadePlayer?.play()

        // Animate the crossfade over the duration
        let steps = max(1, Int(crossfadeDuration * 20))  // 20 steps per second
        let stepDuration = crossfadeDuration / Double(steps)

        crossfadeTask = Task {
            await performCrossfadeAnimation(steps: steps, stepDuration: stepDuration,
                                            newDuration: newDurationSeconds, generation: generation)
        }
    }

    private func performCrossfadeAnimation(steps: Int, stepDuration: Double, newDuration: TimeInterval,
                                           generation: UInt64) async {
        for i in 0...steps {
            guard !Task.isCancelled, generation == loadGeneration else { return }

            let progress = Float(i) / Float(steps)

            // Linear fade for volume
            let fadeOutVolume = (1 - progress) * userVolume * replayGainMultiplier
            let fadeInVolume = progress * userVolume * replayGainMultiplier

            player?.volume = min(fadeOutVolume, 1.0)
            crossfadePlayer?.volume = min(fadeInVolume, 1.0)

            try? await Task.sleep(for: .seconds(stepDuration))
        }

        // Never swap or clear players after a newer owner has taken over.
        guard !Task.isCancelled, generation == loadGeneration else { return }
        completeCrossfade(newDuration: newDuration)
    }

    private func stopCrossfade() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        crossfadePlayer?.pause()
        crossfadePlayer?.replaceCurrentItem(with: nil)
        crossfadePlayer = nil
        crossfadePreparedDuration = nil
        isCrossfading = false
        if let crossfadeFinishedObserver {
            NotificationCenter.default.removeObserver(crossfadeFinishedObserver)
            self.crossfadeFinishedObserver = nil
        }
    }

    private func completeCrossfade(newDuration: TimeInterval) {
        // Save the new track's observer BEFORE removeObservers() clears it
        let newTrackObserver = crossfadeFinishedObserver
        crossfadeFinishedObserver = nil

        // Stop and clean up old player (removes old finishedObserver + timeObserver)
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        // Swap players
        player = crossfadePlayer
        crossfadePlayer = nil
        playerItem = player?.currentItem
        activeSeekOwnershipID = currentRestorationID
        latestSeekRequestGeneration = 0
        duration = newDuration
        crossfadePreparedDuration = nil

        // Set the saved observer as the main finished observer
        finishedObserver = newTrackObserver

        startTimeTracking()
        applyVolume()
        isCrossfading = false
    }

    // MARK: - Callbacks

    func setOnTimeUpdate(_ callback: @escaping @Sendable (TimeInterval) -> Void) {
        onTimeUpdate = callback
    }

    func setOnTrackFinished(_ callback: @escaping @Sendable () -> Void) {
        onTrackFinished = callback
    }

    // MARK: - Private

    private func startTimeTracking() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        guard let playerItem else { return }
        let itemIdentity = ObjectIdentifier(playerItem)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                Task { await self?.notifyTimeUpdate(seconds, itemIdentity: itemIdentity) }
            }
        }
    }

    private func notifyTimeUpdate(_ time: TimeInterval, itemIdentity: ObjectIdentifier) {
        guard playerItem.map(ObjectIdentifier.init) == itemIdentity else { return }
        onTimeUpdate?(time)
    }

    private func removeObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = finishedObserver {
            NotificationCenter.default.removeObserver(observer)
            finishedObserver = nil
        }
        if let observer = crossfadeFinishedObserver {
            NotificationCenter.default.removeObserver(observer)
            crossfadeFinishedObserver = nil
        }
    }

    private func handleTrackFinished(itemIdentity: ObjectIdentifier? = nil) {
        if let itemIdentity, playerItem.map(ObjectIdentifier.init) != itemIdentity,
           crossfadePlayer?.currentItem.map(ObjectIdentifier.init) != itemIdentity { return }
        isPlaying = false
        onTrackFinished?()
    }
}
