import SwiftUI

struct MenuBarPlayerView: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private let size: CGFloat = 300

    private let totalHeight: CGFloat = 340  // Square-ish like Apple Music

    var body: some View {
        ZStack {
            if let song = appState.nowPlaying {
                // Album art - fills ENTIRE view edge-to-edge
                EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .extraLarge, flexible: true)
                    .frame(width: size, height: totalHeight)
                    .clipped()

                // Gradient overlay for legibility
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                }

                // Content overlay
                VStack(spacing: 0) {
                    // Top controls - hover only
                    if isHovering {
                        topControls
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer()

                    // Center controls - hover only
                    if isHovering {
                        centerControls
                            .transition(.opacity)
                    }

                    Spacer()

                    // Bottom - always visible
                    bottomSection(song: song)
                }
            } else {
                emptyState
            }
        }
        .frame(width: size, height: totalHeight)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Top Controls

    private var topControls: some View {
        HStack {
            Button {
                appState.shuffleEnabled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(appState.shuffleEnabled ? .white : .white.opacity(0.5))
            }
            .accessibilityLabel("Shuffle")
            .accessibilityHint(appState.shuffleEnabled ? "Disable shuffle" : "Enable shuffle")

            Spacer()

            // Heart/favorite
            Button {
                Task {
                    if let song = appState.nowPlaying {
                        if song.starred != nil {
                            try? await appState.networkActor.unstar(id: song.id, type: .song)
                        } else {
                            try? await appState.networkActor.star(id: song.id, type: .song)
                        }
                    }
                }
            } label: {
                Image(systemName: appState.nowPlaying?.starred != nil ? "heart.fill" : "heart")
                    .foregroundStyle(appState.nowPlaying?.starred != nil ? .red : .white)
            }
            .accessibilityLabel(appState.nowPlaying?.starred != nil ? "Unlike" : "Like")
            .accessibilityHint(appState.nowPlaying?.starred != nil ? "Remove from favorites" : "Add to favorites")

            // More options menu
            Menu {
                if let song = appState.nowPlaying {
                    Button("Go to Album") {
                        appState.navigationTargetAlbumId = song.albumId
                    }
                    Button("Go to Artist") {
                        appState.navigationTargetArtistId = song.artistId
                    }
                    Divider()
                    Button("Add to Playlist...") {
                        // TODO: show playlist picker
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .font(.callout)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: - Center Controls

    private var centerControls: some View {
        HStack(spacing: 28) {
            Button {
                Task { await appState.playbackManager.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Previous")
            .accessibilityHint("Play previous track")

            Button {
                Task { await appState.playbackManager.togglePlayPause() }
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
            }
            .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
            .accessibilityHint(appState.playbackState == .playing ? "Pause playback" : "Resume playback")

            Button {
                Task { await appState.playbackManager.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Next")
            .accessibilityHint("Play next track")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: - Bottom Section

    private func bottomSection(song: Song) -> some View {
        VStack(spacing: 6) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.3))

                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)
            .gesture(seekGesture)

            // Time
            HStack {
                Text(formatTime(appState.currentTime))
                Spacer()
                Text(formatTime(appState.duration))
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
            .monospacedDigit()

            // Song info
            VStack(spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("\(song.artist) — \(song.album)")
                    .font(.caption)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)

            // Volume
            HStack(spacing: 6) {
                Image(systemName: appState.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption2)
                    .frame(width: 14)

                Slider(value: Binding(
                    get: { Double(appState.volume) },
                    set: { appState.volume = Float($0) }
                ))
                .controlSize(.small)
                .tint(.white)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .frame(width: 14)
            }
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 36))
                .opacity(0.3)

            Text("Not Playing")
                .font(.caption)
                .opacity(0.5)
        }
        .foregroundStyle(.white)
        .frame(width: size, height: 200)
    }

    // MARK: - Helpers

    private var progress: Double {
        guard appState.duration > 0 else { return 0 }
        return appState.currentTime / appState.duration
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let proportion = max(0, min(1, value.location.x / (size - 32)))
                let newTime = proportion * appState.duration
                Task { await appState.playbackManager.seek(to: newTime) }
            }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    MenuBarPlayerView()
        .environment(AppState())
}
