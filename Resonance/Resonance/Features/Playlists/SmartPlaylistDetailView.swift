import SwiftUI

struct SmartPlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    let playlist: SmartPlaylist

    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var selection = Set<String>()
    @State private var loadErrorMessage: String?
    @State private var showingDeleteConfirm = false

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

                    Text("\(songs.count) songs • \(totalDuration) \(playlist.ruleGroup.conjunction == .and ? "(match all)" : "(match any)")")
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
                        showingDeleteConfirm = true
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
            } else if let loadErrorMessage {
                CompactStatusView(
                    title: "Couldn't Evaluate",
                    systemImage: "exclamationmark.triangle",
                    message: loadErrorMessage,
                    actionTitle: "Retry",
                    actionSystemImage: "arrow.clockwise",
                    action: {
                        refreshPlaylist()
                    }
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // Re-evaluate whenever the playlist value changes (e.g. rule edits).
        .task(id: playlist) {
            await loadSongs()
        }
        .confirmationDialog(
            "Delete Smart Playlist?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePlaylist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(playlist.name)\"? Its rules are removed; your songs are not affected.")
        }
    }

    private var totalDuration: String {
        let total = songs.reduce(0) { $0 + $1.duration }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }

    private func loadSongs() async {
        isLoading = true
        loadErrorMessage = nil
        guard let serverId = appState.activeServerId else {
            isLoading = false
            loadErrorMessage = "Select a server to evaluate this smart playlist."
            return
        }

        // Re-evaluate to get fresh results, distinguishing evaluation failure
        // from a genuine zero-match result.
        do {
            _ = try appState.databaseManager.evaluateSmartPlaylist(playlist)
        } catch {
            isLoading = false
            loadErrorMessage = "The playlist rules could not be evaluated. \(error.localizedDescription)"
            return
        }

        do {
            songs = try appState.databaseManager.loadSmartPlaylistSongs(
                playlistId: playlist.id, serverId: serverId
            )
        } catch {
            isLoading = false
            loadErrorMessage = "Matched songs could not be loaded. \(error.localizedDescription)"
            return
        }
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
        do {
            try appState.databaseManager.deleteSmartPlaylist(id: playlist.id)
            appState.smartPlaylists = (try? appState.databaseManager.loadSmartPlaylists(serverId: serverId)) ?? []
        } catch {
            appState.showFeedback(
                message: "Couldn't delete \"\(playlist.name)\"",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}
