import AVFoundation
import Combine

actor AudioActor {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?

    // Crossfade support
    private var crossfadePlayer: AVPlayer?
    private var crossfadeDuration: TimeInterval = 0
    private var isCrossfading = false
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

    func play(url: URL) async throws {
        // Stop and clean up old player completely
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item

        if let durationCMTime = try? await asset.load(.duration) {
            let loadedDuration = CMTimeGetSeconds(durationCMTime)
            duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
        } else {
            duration = 0
        }

        finishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleTrackFinished() }
        }

        // Create a fresh player for each song to avoid state carryover
        player = AVPlayer(playerItem: item)
        player?.allowsExternalPlayback = true
        applyVolume()
        player?.play()
        isPlaying = true

        startTimeTracking()
    }

    func pause() {
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
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        isPlaying = false
    }

    func seek(to time: TimeInterval) async {
        let clampedTime = max(0, min(time, duration))
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        await player?.seek(to: cmTime)
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

    // MARK: - EQ (stub - not supported with AVPlayer)
    // AVPlayer does not expose the DSP pipeline needed to implement these controls.

    func setEQEnabled(_ enabled: Bool) {}
    func setEQBand(_ index: Int, gain: Float) {}
    func setEQPreset(_ gains: [Float]) {}
    func setEQBands(_ gains: [Float]) {}
    func getEQBands() -> [Float] { Array(repeating: 0, count: 10) }

    // MARK: - Crossfade

    func setCrossfadeDuration(_ newDuration: TimeInterval) {
        crossfadeDuration = newDuration
    }

    func getCrossfadeDuration() -> TimeInterval {
        crossfadeDuration
    }

    /// Crossfade to a new track with volume interpolation
    func crossfadeTo(url: URL) async throws {
        // If crossfade is disabled or no current track, just play normally
        guard crossfadeDuration > 0, isPlaying, player != nil else {
            try await play(url: url)
            return
        }

        isCrossfading = true

        // Cancel any existing crossfade
        crossfadeTask?.cancel()

        // Create new player for incoming track
        crossfadePlayer = AVPlayer()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let newDuration = try await asset.load(.duration)
        let newDurationSeconds = CMTimeGetSeconds(newDuration)

        crossfadePlayer?.replaceCurrentItem(with: item)
        crossfadePlayer?.volume = 0  // Start silent

        // Register end-of-track observer IMMEDIATELY so we don't miss the notification
        crossfadeFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleTrackFinished() }
        }

        // Start playing the new track
        crossfadePlayer?.play()

        // Animate the crossfade over the duration
        let steps = Int(crossfadeDuration * 20)  // 20 steps per second
        let stepDuration = crossfadeDuration / Double(steps)

        crossfadeTask = Task {
            await performCrossfadeAnimation(steps: steps, stepDuration: stepDuration, newDuration: newDurationSeconds)
        }
    }

    private func performCrossfadeAnimation(steps: Int, stepDuration: Double, newDuration: TimeInterval) async {
        for i in 0...steps {
            guard !Task.isCancelled else { break }

            let progress = Float(i) / Float(steps)

            // Linear fade for volume
            let fadeOutVolume = (1 - progress) * userVolume * replayGainMultiplier
            let fadeInVolume = progress * userVolume * replayGainMultiplier

            player?.volume = min(fadeOutVolume, 1.0)
            crossfadePlayer?.volume = min(fadeInVolume, 1.0)

            try? await Task.sleep(for: .seconds(stepDuration))
        }

        // Crossfade complete - swap players
        completeCrossfade(newDuration: newDuration)
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
        duration = newDuration

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
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                Task { await self?.notifyTimeUpdate(seconds) }
            }
        }
    }

    private func notifyTimeUpdate(_ time: TimeInterval) {
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

    private func handleTrackFinished() {
        isPlaying = false
        onTrackFinished?()
    }
}
