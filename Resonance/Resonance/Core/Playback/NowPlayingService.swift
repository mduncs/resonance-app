import AppKit
import Foundation
import MediaPlayer

final class NowPlayingService {
    private let infoCenter = MPNowPlayingInfoCenter.default()

    func update(song: Song, isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let track = song.track {
            info[MPMediaItemPropertyAlbumTrackNumber] = track
        }

        if let year = song.year {
            // MPMediaItemPropertyYear doesn't exist, could use release date
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func updateTime(currentTime: TimeInterval, isPlaying: Bool) {
        guard var info = infoCenter.nowPlayingInfo else { return }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        infoCenter.nowPlayingInfo = info
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    // MARK: - Artwork

    func setArtwork(_ image: NSImage) {
        guard var info = infoCenter.nowPlayingInfo else { return }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        info[MPMediaItemPropertyArtwork] = artwork

        infoCenter.nowPlayingInfo = info
    }
}
