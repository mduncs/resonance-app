import SwiftUI

struct ImmersiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emotionEngine) private var emotionEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Animated gradient background using EmotionEngine colors
                EmotionGradientBackground(
                    primaryColor: emotionEngine.primaryColor,
                    secondaryColor: emotionEngine.secondaryColor,
                    backgroundColor: emotionEngine.backgroundColor.opacity(0.3).blended(with: .black),
                    isPlaying: appState.playbackState == .playing
                )

                // Subtle vignette overlay
                RadialGradient(
                    colors: [.clear, .black.opacity(0.3)],
                    center: .center,
                    startRadius: geometry.size.width * 0.3,
                    endRadius: geometry.size.width * 0.8
                )

                VStack(spacing: 40) {
                    Spacer()

                    // Album art
                    if let song = appState.nowPlaying {
                        EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .large)
                            .frame(width: min(geometry.size.width * 0.5, 400),
                                   height: min(geometry.size.width * 0.5, 400))
                            .cornerRadius(12)
                            .shadow(radius: 30)
                    }

                    // Song info
                    VStack(spacing: 8) {
                        if let song = appState.nowPlaying {
                            Text(song.title)
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)

                            Text(song.artist)
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    // Progress
                    VStack(spacing: 8) {
                        SeekBar()
                            .tint(.white)

                        HStack {
                            Text(formatTime(appState.currentTime))
                            Spacer()
                            Text(formatTime(appState.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                    }
                    .frame(maxWidth: 500)
                    .padding(.horizontal, 40)

                    // Controls
                    HStack(spacing: 40) {
                        Button {
                            appState.shuffleEnabled.toggle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.title2)
                                .foregroundStyle(appState.shuffleEnabled ? .white : .white.opacity(0.5))
                        }
                        .accessibilityLabel("Shuffle")
                        .accessibilityHint(appState.shuffleEnabled ? "Disable shuffle" : "Enable shuffle")

                        Button {
                            Task { await appState.playbackManager.previous() }
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Previous")
                        .accessibilityHint("Play previous track")

                        Button {
                            Task { await appState.playbackManager.togglePlayPause() }
                        } label: {
                            Image(systemName: appState.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 70))
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
                        .accessibilityHint(appState.playbackState == .playing ? "Pause playback" : "Resume playback")

                        Button {
                            Task { await appState.playbackManager.next() }
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Next")
                        .accessibilityHint("Play next track")

                        Button {
                            appState.playbackManager.cycleRepeatMode()
                        } label: {
                            Image(systemName: repeatIcon)
                                .font(.title2)
                                .foregroundStyle(appState.playbackManager.repeatMode != .off ? .white : .white.opacity(0.5))
                        }
                        .accessibilityLabel("Repeat")
                        .accessibilityHint(repeatAccessibilityHint)
                    }
                    .buttonStyle(.plain)

                    // Volume control
                    HStack(spacing: 12) {
                        Image(systemName: volumeIcon)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 20)

                        Slider(value: Binding(
                            get: { Double(appState.volume) },
                            set: { appState.volume = Float($0) }
                        ))
                        .frame(width: 200)
                        .tint(.white)
                        .accessibilityLabel("Volume")

                        Image(systemName: "speaker.wave.3.fill")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 20)
                    }
                    .padding(.top, 20)

                    // Lyrics (if visible)
                    if appState.isLyricsPanelVisible {
                        LyricsView()
                            .frame(maxWidth: 600, maxHeight: 200)
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                    }

                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .onTapGesture(count: 2) {
            dismiss()
        }
    }

    private var repeatIcon: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat.circle.fill"
        }
    }

    private var repeatAccessibilityHint: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "Currently off. Tap to repeat all"
        case .all: return "Currently repeat all. Tap to repeat one"
        case .one: return "Currently repeat one. Tap to turn off"
        }
    }

    private var volumeIcon: String {
        if appState.volume < 0.01 { return "speaker.slash.fill" }
        else if appState.volume < 0.33 { return "speaker.wave.1.fill" }
        else if appState.volume < 0.66 { return "speaker.wave.2.fill" }
        else { return "speaker.wave.3.fill" }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ImmersiveView()
        .environment(AppState())
}
