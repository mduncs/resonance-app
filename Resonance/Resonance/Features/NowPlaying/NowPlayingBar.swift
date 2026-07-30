import SwiftUI

struct NowPlayingBar: View {
    @Environment(AppState.self) private var appState
    @State private var isProgressHovered = false

    private struct LayoutMetrics {
        let controlsWidth: CGFloat
        let utilitiesWidth: CGFloat
        let horizontalPadding: CGFloat
        let sectionSpacing: CGFloat
        let controlSpacing: CGFloat
        let volumeSliderWidth: CGFloat
        let albumArtSize: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = layoutMetrics(for: geometry.size.width)

            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    playbackControls(metrics: metrics)
                        .frame(width: metrics.controlsWidth)

                    Spacer()
                        .frame(width: metrics.sectionSpacing)

                    centerSection(metrics: metrics)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()
                        .frame(width: metrics.sectionSpacing)

                    rightControls(metrics: metrics)
                        .frame(width: metrics.utilitiesWidth)
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 54)
        .modifier(GlassEffectModifier(shape: .capsule))
        .accessibilityIdentifier("NowPlayingBar")
        .accessibilityLabel("Now Playing Bar")
    }

    // MARK: - Center Section (album art, song info, progress bar directly underneath)

    private func centerSection(metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Album art + song info with optional blur on progress hover
            ZStack(alignment: .leading) {
                nowPlayingInfo(albumArtSize: metrics.albumArtSize)
                    .blur(radius: isProgressHovered ? 8 : 0)
                    .opacity(isProgressHovered ? 0.6 : 1)

                // Time display overlay - appears on hover
                if appState.nowPlaying != nil && appState.currentDuration > 0 && appState.playbackManager.currentSourceSupportsSeeking && isProgressHovered {
                    HStack {
                        Text(formatTime(appState.currentTime))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("-\(formatTime(appState.currentDuration - appState.currentTime))")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .modifier(ProgressHoverGlassModifier(isHovered: isProgressHovered))
            .animation(.easeInOut(duration: 0.15), value: isProgressHovered)

            // Progress bar directly underneath album info
            if appState.nowPlaying != nil && appState.currentDuration > 0 && appState.playbackManager.currentSourceSupportsSeeking {
                progressBar
                    .frame(height: isProgressHovered ? 4 : 2)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .animation(.easeInOut(duration: 0.15), value: isProgressHovered)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Glass Effect Modifiers

    private struct GlassEffectModifier: ViewModifier {
        let shape: AnyShape

        init(shape: some Shape) {
            self.shape = AnyShape(shape)
        }

        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background { shape.fill(.ultraThinMaterial) }
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }
        }
    }

    private struct ProgressHoverGlassModifier: ViewModifier {
        let isHovered: Bool

        func body(content: Content) -> some View {
            // Always apply padding to prevent layout shift on hover toggle
            content
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
                    }
                }
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(isProgressHovered ? 0.3 : 0.15))

                // Progress
                Capsule()
                    .fill(Color.white.opacity(isProgressHovered ? 0.8 : 0.5))
                    .frame(width: progressWidth(in: geometry.size.width))
            }
            .contentShape(Rectangle().size(width: geometry.size.width, height: 24))
            .onHover { isProgressHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        Task {
                            await appState.playbackManager.seek(to: progress * appState.currentDuration)
                        }
                    }
            )
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard appState.currentDuration > 0 else { return 0 }
        return totalWidth * CGFloat(appState.currentTime / appState.currentDuration)
    }

    // MARK: - Playback Controls (Apple Music sizes, tighter spacing)

    private func playbackControls(metrics: LayoutMetrics) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            Button {
                appState.queueManager.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.queueManager.isShuffleEnabled ? Color.accentColor : .primary)

            Button {
                Task { await appState.playbackManager.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .opacity(appState.playbackManager.canGoPrevious ? 1.0 : 0.3)

            Button {
                Task {
                    if appState.nowPlaying == nil {
                        await resumeFromHistory()
                    } else {
                        await appState.playbackManager.togglePlayPause()
                    }
                }
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                Task { await appState.playbackManager.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .opacity(appState.playbackManager.canGoNext ? 1.0 : 0.3)

            Button {
                appState.playbackManager.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.playbackManager.repeatMode != .off ? Color.accentColor : .primary)
        }
    }

    // MARK: - Now Playing Info (35px art, bold title, Artist - Album below)

    @ViewBuilder
    private func nowPlayingInfo(albumArtSize: CGFloat) -> some View {
        if let song = appState.nowPlaying {
            HStack(spacing: 10) {
                // Album art - click for menu, right-click same menu
                AlbumArtMenuButton(song: song, size: albumArtSize)

                // Song info - title bold, "Artist - Album" below
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: song.title, font: .system(size: 12, weight: .bold))
                        .onTapGesture { navigateToAlbumWithSong(albumId: song.albumId, songId: song.id) }

                    MarqueeText(
                        text: "\(song.artist) — \(song.album)",
                        font: .system(size: 10),
                        color: .secondary
                    )
                    .onTapGesture { navigateToArtist(song.artistId) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    SongContextMenu(song: song)
                }
            }
            .padding(.leading, 8) // Extra left spacing
        } else {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: albumArtSize, height: albumArtSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Not Playing")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("Select a song")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
        }
    }

    // MARK: - Right Controls (14px spacing per spec)

    private func rightControls(metrics: LayoutMetrics) -> some View {
        HStack(spacing: metrics.controlSpacing) {
            // Volume (always visible)
            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Slider(value: Binding(
                    get: { Double(appState.volume) },
                    set: { appState.volume = Float($0) }
                ), in: 0...1)
                    .frame(width: metrics.volumeSliderWidth)
                    .controlSize(.mini)
                    .tint(.primary.opacity(0.6))
            }

            // AutoPlay ∞
            AutoPlayToggle()

            if let song = appState.nowPlaying {
                QuickCaptureMenu(song: song) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Quick Capture")
            }

            // Queue
            Button {
                appState.isQueueVisible.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isQueueVisible ? Color.accentColor : .secondary)

            // Lyrics
            Button {
                appState.isLyricsPanelVisible.toggle()
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isLyricsPanelVisible ? Color.accentColor : .secondary)
        }
    }

    // MARK: - Helpers

    private func layoutMetrics(for width: CGFloat) -> LayoutMetrics {
        switch width {
        case ..<520:
            LayoutMetrics(
                controlsWidth: 118,
                utilitiesWidth: 132,
                horizontalPadding: 14,
                sectionSpacing: 10,
                controlSpacing: 10,
                volumeSliderWidth: 38,
                albumArtSize: 30
            )
        case ..<660:
            LayoutMetrics(
                controlsWidth: 132,
                utilitiesWidth: 150,
                horizontalPadding: 16,
                sectionSpacing: 12,
                controlSpacing: 12,
                volumeSliderWidth: 48,
                albumArtSize: 32
            )
        case ..<820:
            LayoutMetrics(
                controlsWidth: 144,
                utilitiesWidth: 166,
                horizontalPadding: 18,
                sectionSpacing: 16,
                controlSpacing: 13,
                volumeSliderWidth: 54,
                albumArtSize: 34
            )
        default:
            LayoutMetrics(
                controlsWidth: 150,
                utilitiesWidth: 178,
                horizontalPadding: 20,
                sectionSpacing: 20,
                controlSpacing: 14,
                volumeSliderWidth: 60,
                albumArtSize: 35
            )
        }
    }

    private func navigateToAlbum(_ albumId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetSongId = nil  // Clear any song highlight
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    private func navigateToAlbumWithSong(albumId: String, songId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetSongId = songId  // Highlight this song
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    private func navigateToArtist(_ artistId: String) {
        guard !artistId.isEmpty else { return }
        appState.navigationTargetArtistId = artistId
        appState.selectedSidebarItem = .artists
    }

    private func resumeFromHistory() async {
        let history = (try? appState.databaseManager.loadPlayHistory(
            serverId: appState.activeServerId,
            limit: 1
        )) ?? []

        if let lastPlayed = history.first {
            do {
                let songs = appState.visibleSongsForPlayback(
                    try await appState.networkActor.fetchAlbumSongs(albumId: lastPlayed.albumId)
                )
                if let startIndex = songs.firstIndex(where: { $0.id == lastPlayed.songId }) {
                    await appState.playbackManager.play(songs: Array(songs.suffix(from: startIndex)))
                    return
                } else if !songs.isEmpty {
                    await appState.playbackManager.play(songs: songs)
                    return
                }
            } catch {
                print("Failed to resume from history: \(error)")
            }
        }

        // Fallback: play a random album ("Made for You")
        do {
            let albums = try await appState.networkActor.fetchAlbums(type: .random, size: 1)
            if let album = albums.first {
                let songs = try await appState.playableAlbumSongs(for: album)
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play random album: \(error)")
        }
    }

    private var volumeIcon: String {
        if appState.volume < 0.01 { return "speaker.slash.fill" }
        else if appState.volume < 0.33 { return "speaker.wave.1.fill" }
        else if appState.volume < 0.66 { return "speaker.wave.2.fill" }
        else { return "speaker.wave.3.fill" }
    }

    private var repeatIcon: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat.circle.fill"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Album Art Menu Button (left-click = menu, same as right-click)

private struct AlbumArtMenuButton: View {
    @Environment(AppState.self) private var appState
    let song: Song
    let size: CGFloat

    var body: some View {
        EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .miniBar)
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
            .overlay { MenuTriggerView(song: song, size: size) }
            .contextMenu {
                menuItems
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { navigateToAlbum(song.albumId) } label: {
            Label("Go to Album", systemImage: "square.stack")
        }
        Divider()
        Button { appState.showMiniPlayer() } label: {
            Label("MiniPlayer", systemImage: "pip")
        }
        Button { appState.enterImmersiveMode() } label: {
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private func navigateToAlbum(_ albumId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetSongId = nil
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    /// NSView overlay that intercepts left-click and shows NSMenu
    struct MenuTriggerView: NSViewRepresentable {
        @Environment(AppState.self) private var appState
        let song: Song
        let size: CGFloat

        func makeNSView(context: Context) -> MenuTriggerNSView {
            let view = MenuTriggerNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            view.wantsLayer = true
            view.layer?.backgroundColor = .clear
            view.context = context.coordinator
            return view
        }

        func updateNSView(_ nsView: MenuTriggerNSView, context: Context) {
            nsView.context = context.coordinator
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(appState: appState, song: song)
        }

        class Coordinator {
            let appState: AppState
            let song: Song
            init(appState: AppState, song: Song) {
                self.appState = appState
                self.song = song
            }
        }
    }
}

private class MenuTriggerNSView: NSView {
    var context: AlbumArtMenuButton.MenuTriggerView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        guard let context else { super.mouseDown(with: event); return }

        let menu = NSMenu()
        let handler = MenuActionHandler(appState: context.appState, song: context.song)
        // Prevent dealloc during menu display
        objc_setAssociatedObject(menu, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let goToAlbum = NSMenuItem(title: "Go to Album", action: #selector(MenuActionHandler.goToAlbum), keyEquivalent: "")
        goToAlbum.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        goToAlbum.target = handler
        menu.addItem(goToAlbum)

        menu.addItem(.separator())

        let miniPlayer = NSMenuItem(title: "MiniPlayer", action: #selector(MenuActionHandler.showMiniPlayer), keyEquivalent: "")
        miniPlayer.image = NSImage(systemSymbolName: "pip", accessibilityDescription: nil)
        miniPlayer.target = handler
        menu.addItem(miniPlayer)

        let fullScreen = NSMenuItem(title: "Full Screen", action: #selector(MenuActionHandler.enterImmersive), keyEquivalent: "")
        fullScreen.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        fullScreen.target = handler
        menu.addItem(fullScreen)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
}

@MainActor
private class MenuActionHandler: NSObject {
    let appState: AppState
    let song: Song

    init(appState: AppState, song: Song) {
        self.appState = appState
        self.song = song
    }

    @objc func goToAlbum() {
        appState.navigationTargetSongId = nil
        appState.navigationTargetAlbumId = song.albumId
        appState.selectedSidebarItem = .albums
    }

    @objc func showMiniPlayer() {
        appState.showMiniPlayer()
    }

    @objc func enterImmersive() {
        appState.enterImmersiveMode()
    }
}

// MARK: - AutoPlay Toggle

struct AutoPlayToggle: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.isAutoPlayEnabled.toggle()
        } label: {
            Image(systemName: "infinity")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.isAutoPlayEnabled ? Color.accentColor : .secondary)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Marquee Text (shows ... when truncated, smooth scroll after 1s hover)

struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .primary

    @State private var isHovered = false
    @State private var shouldScroll = false
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let scrollSpeed: CGFloat = 30
    private let hoverDelay: TimeInterval = 1.0
    private let pauseAtEnd: TimeInterval = 1.0

    private var isTruncated: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    var body: some View {
        GeometryReader { geometry in
            let containerW = geometry.size.width

            ZStack(alignment: .leading) {
                // Hidden: measure full text width
                Text(text)
                    .font(font)
                    .fixedSize()
                    .background(GeometryReader { textGeo in
                        Color.clear
                            .onAppear { textWidth = textGeo.size.width }
                            .onChange(of: text) { _, _ in
                                textWidth = textGeo.size.width
                                resetScroll()
                            }
                    })
                    .hidden()

                // DEFAULT: Truncated with ellipsis
                if !shouldScroll {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .frame(maxWidth: containerW, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // SCROLLING: Full text that moves smoothly
                if shouldScroll {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .frame(width: containerW, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = containerW
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                containerWidth = newWidth
                resetScroll()
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering && isTruncated {
                startScrollAfterDelay()
            } else {
                resetScroll()
            }
        }
    }

    private var scrollDuration: TimeInterval {
        guard textWidth > containerWidth else { return 0 }
        let distance = textWidth - containerWidth + 20
        return Double(distance) / Double(scrollSpeed)
    }

    private func startScrollAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(hoverDelay))
            guard isHovered, isTruncated else { return }
            await MainActor.run {
                shouldScroll = true
                offset = 0
                startScrollLoop()
            }
        }
    }

    private func startScrollLoop() {
        let distance = textWidth - containerWidth + 20

        // Small delay then smooth animate to scrolled position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.linear(duration: scrollDuration)) {
                offset = -distance
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(scrollDuration + pauseAtEnd + 0.05))
            guard isHovered else { return }
            await MainActor.run {
                offset = 0  // Jump back instantly
                if isHovered && isTruncated {
                    Task {
                        try? await Task.sleep(for: .seconds(pauseAtEnd))
                        if isHovered {
                            startScrollLoop()
                        }
                    }
                }
            }
        }
    }

    private func resetScroll() {
        shouldScroll = false
        offset = 0
    }
}

#Preview {
    NowPlayingBar()
        .environment(AppState())
}
