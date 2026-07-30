import SwiftUI

struct ListenView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var selectedPanel: ListenPanel = .queue

    var body: some View {
        Group {
            if appState.activeServer == nil && appState.nowPlaying == nil {
                noServerStartView
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 820 {
                        compactLayout
                    } else {
                        regularLayout
                    }
                }
            }
        }
        .navigationTitle("Listen")
    }

    private var noServerStartView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Listen")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Connect a server when you are ready to start listening.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Server Connected")
                            .font(.headline)

                        Text("Add a Navidrome or Subsonic-compatible server from Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        openServerSettings()
                    } label: {
                        Label("Add Server", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            playerColumn
                .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            sidePanel
                .frame(width: 340)
                .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                playerColumn
                    .padding(.bottom, 12)
            }

            Divider()

            sidePanel
                .frame(height: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var playerColumn: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 10)

            nowPlayingArtwork

            trackIdentity
                .frame(maxWidth: 520)

            playbackSurface
                .frame(maxWidth: 560)

            quickCaptureStrip
                .frame(maxWidth: 620)

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var nowPlayingArtwork: some View {
        if let song = appState.nowPlaying {
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .extraLarge, flexible: true)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var trackIdentity: some View {
        VStack(spacing: 5) {
            Text(appState.nowPlaying?.title ?? "Not Playing")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var playbackSurface: some View {
        VStack(spacing: 14) {
            if appState.nowPlaying != nil && appState.currentDuration > 0 && appState.playbackManager.currentSourceSupportsSeeking {
                SeekBar()
            } else {
                SeekBarCompact()
            }

            PlaybackControls(size: .large)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var quickCaptureStrip: some View {
        HStack(spacing: 8) {
            if let song = appState.nowPlaying {
                QuickCaptureMenu(song: song) {
                    Label("Capture", systemImage: "bolt.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Quick Capture")

                Divider()
                    .frame(height: 22)
            }

            ListenActionButton("Similar", systemImage: "sparkles") {
                guard let song = appState.nowPlaying else { return }
                appState.similarSongsSeedSong = song
                appState.showSimilarSongsSheet = true
            }
            .disabled(appState.nowPlaying == nil)

            ListenActionButton("Info", systemImage: "info.circle") {
                guard let song = appState.nowPlaying else { return }
                appState.getInfoContent = .song(song)
            }
            .disabled(appState.nowPlaying == nil)

            ListenActionButton("Playlist", systemImage: "text.badge.plus") {
                appState.createPlaylistSongIds = appState.nowPlaying.map { [$0.id] } ?? []
                appState.showCreatePlaylistSheet = true
            }

            Divider()
                .frame(height: 22)

            ListenActionButton("Mini", systemImage: "pip") {
                appState.showMiniPlayer()
            }

            ListenActionButton("Immersive", systemImage: "rectangle.inset.filled") {
                appState.enterImmersiveMode()
            }

            Divider()
                .frame(height: 22)

            ListenActionButton("Lyrics", systemImage: "quote.bubble") {
                appState.isLyricsPanelVisible.toggle()
                selectedPanel = .lyrics
            }

            ListenActionButton("Queue", systemImage: "music.note.list") {
                appState.isQueueVisible.toggle()
                selectedPanel = .queue
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $selectedPanel) {
                ForEach(ListenPanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.systemImage)
                        .tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                switch selectedPanel {
                case .queue:
                    ContinuePlayingPanel()
                case .lyrics:
                    LyricsView()
                        .background(.ultraThinMaterial)
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    private var subtitle: String {
        guard let song = appState.nowPlaying else {
            return "Choose a track from your library"
        }

        if song.album.isEmpty {
            return song.artist
        }

        return "\(song.artist) - \(song.album)"
    }

    private func openServerSettings() {
        UserDefaults.standard.set(SettingsTab.server.rawValue, forKey: SettingsTab.storageKey)
        openSettings()
    }
}

private enum ListenPanel: String, CaseIterable, Identifiable {
    case queue
    case lyrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Queue"
        case .lyrics: return "Lyrics"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: return "music.note.list"
        case .lyrics: return "quote.bubble"
        }
    }
}

private struct ListenActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

#Preview {
    ListenView()
        .frame(width: 1040, height: 720)
        .environment(AppState())
}
