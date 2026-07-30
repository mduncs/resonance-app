import SwiftUI

struct SmartPlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    let playlist: SmartPlaylist

    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(.purple)

                        Text(playlist.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                    }

                    Text("\(songs.count) songs \(playlist.ruleGroup.conjunction == .and ? "(match all)" : "(match any)")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label("Play All", systemImage: "play")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)

                    Divider()

                    Button {
                        refreshPlaylist()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        appState.editSmartPlaylistTarget = playlist
                        appState.showSmartPlaylistEditor = true
                    } label: {
                        Label("Edit Rules", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deletePlaylist()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if isLoading {
                InlineLoadingStatusView(title: "Loading smart playlist...")
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            } else if songs.isEmpty {
                CompactStatusView(
                    title: "No Matching Songs",
                    systemImage: "wand.and.stars",
                    message: "No songs match the current rules. Try editing the playlist.",
                    actionTitle: "Edit Rules",
                    actionSystemImage: "slider.horizontal.3",
                    action: {
                        appState.editSmartPlaylistTarget = playlist
                        appState.showSmartPlaylistEditor = true
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Table(songs, selection: $selection) {
                    TableColumn("#") { song in
                        if let idx = songs.firstIndex(of: song) {
                            Text("\(idx + 1)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .width(40)

                    TableColumn("Title") { song in
                        HStack(spacing: 12) {
                            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                                .frame(width: 32, height: 32)
                                .cornerRadius(4)

                            Text(song.title)
                        }
                    }

                    TableColumn("Artist", value: \.artist)

                    TableColumn("Album", value: \.album)

                    TableColumn("Duration") { song in
                        Text(song.formattedDuration)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(60)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { selectedIds in
                    if let songId = selectedIds.first,
                       let song = songs.first(where: { $0.id == songId }) {
                        SongContextMenu(song: song)
                    }
                } primaryAction: { selectedIds in
                    if let songId = selectedIds.first,
                       let song = songs.first(where: { $0.id == songId }),
                       let index = songs.firstIndex(of: song) {
                        Task {
                            await appState.playbackManager.play(songs: songs, startingAt: index)
                        }
                    }
                }
                .frame(minHeight: 300)
            }
        }
        .task {
            await loadSongs()
        }
    }

    private func loadSongs() async {
        isLoading = true
        guard let serverId = appState.activeServerId else {
            isLoading = false
            return
        }

        // Re-evaluate to get fresh results
        _ = try? appState.databaseManager.evaluateSmartPlaylist(playlist)
        songs = (try? appState.databaseManager.loadSmartPlaylistSongs(
            playlistId: playlist.id, serverId: serverId
        )) ?? []
        isLoading = false
    }

    private func playAll(shuffled: Bool = false) async {
        var songsToPlay = songs
        if shuffled { songsToPlay.shuffle() }
        if !songsToPlay.isEmpty {
            await appState.playbackManager.play(songs: songsToPlay)
        }
    }

    private func refreshPlaylist() {
        Task {
            await loadSongs()
        }
    }

    private func deletePlaylist() {
        guard let serverId = appState.activeServerId else { return }
        try? appState.databaseManager.deleteSmartPlaylist(id: playlist.id)
        appState.smartPlaylists = (try? appState.databaseManager.loadSmartPlaylists(serverId: serverId)) ?? []
    }
}
