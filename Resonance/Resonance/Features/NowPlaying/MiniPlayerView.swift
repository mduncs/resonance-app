import SwiftUI

// MARK: - MiniPlayer Mode

enum MiniPlayerMode: String, CaseIterable {
    case art
    case queue

    var size: CGSize {
        switch self {
        case .art: return CGSize(width: 300, height: 340)
        case .queue: return CGSize(width: 300, height: 500)
        }
    }

    var next: MiniPlayerMode {
        switch self {
        case .art: return .queue
        case .queue: return .art
        }
    }

    private static let userDefaultsKey = "miniPlayerMode"

    static var persisted: MiniPlayerMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
                  let mode = MiniPlayerMode(rawValue: raw) else {
                return .art
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}

// MARK: - MiniPlayerView

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var mode: MiniPlayerMode = MiniPlayerMode.persisted
    @State private var isHovering = false
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    private let artHeight: CGFloat = 340
    private let width: CGFloat = 300
    private let controlsIdleDelay: Duration = .seconds(2)

    var body: some View {
        ZStack {
            if let song = appState.nowPlaying {
                // Album art - fills ENTIRE window including behind traffic lights
                EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .extraLarge, flexible: true)
                    .frame(width: width, height: artHeight)
                    .clipped()
                    .frame(maxHeight: .infinity, alignment: .top)

                artOverlay(song: song)

                // Queue section (below art, fills remaining space)
                if mode == .queue {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: artHeight)
                        queueSection
                            .frame(maxHeight: .infinity)
                    }
                }

                modeToggleButton
            } else {
                emptyState
            }
        }
        .frame(width: width, height: mode.size.height)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .ignoresSafeArea()  // Extend into title bar area
        .onHover { hovering in
            isHovering = hovering
            updateControlsVisibility()
        }
        .onAppear {
            updateControlsVisibility()
        }
        .onDisappear {
            hideControlsTask?.cancel()
        }
        .onChange(of: controlActiveState) {
            updateControlsVisibility()
        }
        .onChange(of: mode) { _, newMode in
            MiniPlayerMode.persisted = newMode
            resizeWindow(to: newMode.size)
        }
    }

    // MARK: - Overlay Controls

    private func artOverlay(song: Song) -> some View {
        VStack(spacing: 0) {
            Spacer()

            if controlsVisible {
                LinearGradient(
                    colors: [.clear, .black.opacity(isHovering ? 0.78 : 0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: isHovering ? 150 : 110)
                .overlay(alignment: .bottom) {
                    Group {
                        if isHovering {
                            hoverControls(song: song)
                                .transition(.opacity)
                        } else {
                            compactControls(song: song)
                        }
                    }
                    .padding(.bottom, 14)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: artHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    private var modeToggleButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { mode = mode.next }
                } label: {
                    Image(systemName: mode == .art ? "list.bullet" : "square")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(isHovering ? 0.55 : 0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .opacity(isHovering ? 1 : 0.72)
            }
            Spacer()
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    private func hoverControls(song: Song) -> some View {
        VStack(spacing: 8) {
            // Time bar
            HStack {
                Text(formatTime(appState.currentTime))
                Spacer()
                Text("-\(formatTime(max(0, appState.duration - appState.currentTime)))")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            .monospacedDigit()

            // Progress scrubber
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.3))
                    Rectangle()
                        .fill(.white)
                        .frame(width: geo.size.width * progressRatio)
                }
                .gesture(seekGesture(width: geo.size.width))
            }
            .frame(height: 3)

            // Song info
            VStack(spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("\(song.artist) — \(song.album)")
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.top, 4)

            // Playback controls - shuffle left, repeat right, transport centered
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

                // Center transport controls
                HStack(spacing: 24) {
                    Button {
                        Task { await appState.playbackManager.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel("Previous")
                    .accessibilityHint("Play previous track")

                    Button {
                        Task { await appState.playbackManager.togglePlayPause() }
                    } label: {
                        Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
                    .accessibilityHint(appState.playbackState == .playing ? "Pause playback" : "Resume playback")

                    Button {
                        Task { await appState.playbackManager.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel("Next")
                    .accessibilityHint("Play next track")
                }

                Spacer()

                // Heart/like button
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
                        .foregroundStyle(appState.nowPlaying?.starred != nil ? .red : .white.opacity(0.5))
                }
                .accessibilityLabel(appState.nowPlaying?.starred != nil ? "Unlike" : "Like")
                .accessibilityHint(appState.nowPlaying?.starred != nil ? "Remove from favorites" : "Add to favorites")
            }
            .font(.callout)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.top, 4)

            // Volume slider
            HStack(spacing: 8) {
                Image(systemName: appState.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption)
                    .frame(width: 14)

                Slider(value: Binding(
                    get: { Double(appState.volume) },
                    set: { appState.volume = Float($0) }
                ))
                .controlSize(.small)
                .tint(.white)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .frame(width: 14)
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
    }

    private func compactControls(song: Song) -> some View {
        VStack(spacing: 10) {
            if appState.duration > 0 && appState.playbackManager.currentSourceSupportsSeeking {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.22))
                        Capsule()
                            .fill(.white.opacity(0.78))
                            .frame(width: geo.size.width * progressRatio)
                    }
                }
                .frame(height: 2)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(song.artist)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.78)
                }

                Spacer(minLength: 8)

                HStack(spacing: 16) {
                    Button {
                        Task { await appState.playbackManager.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                    }

                    Button {
                        Task { await appState.playbackManager.togglePlayPause() }
                    } label: {
                        Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }

                    Button {
                        Task { await appState.playbackManager.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .font(.callout)
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Queue Section

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(.caption)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(appState.queueManager.allUpcomingCount)")
                    .font(.caption2)
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if appState.queueManager.allUpcomingCount == 0 {
                Text("Queue is empty")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.queueManager.upcomingItems(limit: 15)) { item in
                            queueRow(item: item)
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    private func queueRow(item: QueueItem) -> some View {
        HStack(spacing: 10) {
            EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                .frame(width: 32, height: 32)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.song.title)
                    .font(.caption)
                    .lineLimit(1)

                Text(item.song.artist)
                    .font(.caption2)
                    .opacity(0.6)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.song.formattedDuration)
                .font(.caption2)
                .opacity(0.5)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                _ = appState.queueManager.skipTo(id: item.id)
                await appState.playbackManager.play(song: item.song)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 50))
                .opacity(0.3)

            Text("Not Playing")
                .font(.subheadline)
                .opacity(0.5)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var progressRatio: CGFloat {
        guard appState.duration > 0 else { return 0 }
        return min(1.0, appState.currentTime / appState.duration)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let proportion = max(0, min(1, value.location.x / width))
                let newTime = proportion * appState.duration
                Task { await appState.playbackManager.seek(to: newTime) }
            }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateTrafficLights(alpha: CGFloat) {
        // Find window by identifier
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "miniPlayer"
        }) else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            window.standardWindowButton(.closeButton)?.animator().alphaValue = alpha
            window.standardWindowButton(.miniaturizeButton)?.animator().alphaValue = alpha
            window.standardWindowButton(.zoomButton)?.animator().alphaValue = alpha
        }
    }

    private func updateControlsVisibility() {
        hideControlsTask?.cancel()

        if isHovering || controlActiveState == .key {
            withAnimation(.easeInOut(duration: 0.25)) {
                controlsVisible = true
            }
            updateTrafficLights(alpha: isHovering ? 1 : 0.35)
            return
        }

        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: controlsIdleDelay)
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                controlsVisible = false
            }
            updateTrafficLights(alpha: 0)
        }
    }

    private func resizeWindow(to size: CGSize) {
        // Find window by identifier (more reliable than view hierarchy)
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "miniPlayer"
        }) else {
            print("[MiniPlayer] Failed to find window for resize")
            return
        }

        var frame = window.frame
        let heightDiff = size.height - frame.height
        frame.origin.y -= heightDiff
        frame.size = size

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

#Preview {
    MiniPlayerView()
        .environment(AppState())
}
