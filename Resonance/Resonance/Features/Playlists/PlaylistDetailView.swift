import SwiftUI
import UniformTypeIdentifiers

/// Transferable wrapper for playlist song drag & drop
struct PlaylistSongTransfer: Codable, Transferable {
    let songId: String
    let sourceIndex: Int  // Initial index (for preview), but we find current index at drop time

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .playlistSong)
    }
}

extension UTType {
    static var playlistSong: UTType {
        UTType(exportedAs: "com.resonance.playlist-song")
    }
}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    let playlist: Playlist

    @State private var songs: [Song] = []
    @State private var isEditing = false
    @State private var isLoading = true
    @State private var loadError: ResonanceError?
    @State private var draggingSongId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                PlaylistHeaderView(
                    playlist: playlist,
                    songs: songs,
                    onPlay: { playSongs(shuffled: false) },
                    onShuffle: { playSongs(shuffled: true) }
                )

                Divider()
                    .padding(.horizontal)

                // Track list
                if isLoading {
                    InlineLoadingStatusView(title: "Loading songs...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(minHeight: 260)
                } else if let error = loadError {
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription ?? "Playlist songs could not be loaded.",
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise",
                        action: {
                            Task { await loadSongs() }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                } else if songs.isEmpty {
                    CompactStatusView(
                        title: "No Songs",
                        systemImage: "music.note.list",
                        message: "This playlist does not contain any visible songs."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 12) {
                                if isEditing {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.secondary)
                                }

                                SongRow(song: song, showTrackNumber: false)
                            }
                            .opacity(draggingSongId == song.id ? 0.5 : 1.0)
                            .onTapGesture(count: 2) {
                                guard !isEditing else { return }
                                Task {
                                    await appState.playbackManager.play(songs: songs, startingAt: index)
                                }
                            }
                            .contextMenu {
                                SongContextMenu(song: song)

                                Divider()

                                Button(role: .destructive) {
                                    Task {
                                        await removeSongFromPlaylist(at: index)
                                    }
                                } label: {
                                    Label("Remove from Playlist", systemImage: "minus.circle")
                                }
                            }
                            .draggable(PlaylistSongTransfer(songId: song.id, sourceIndex: index)) {
                                // Drag preview
                                SongRow(song: song, showTrackNumber: false)
                                    .frame(width: 280)
                                    .background(.regularMaterial)
                                    .cornerRadius(8)
                            }
                            .dropDestination(for: PlaylistSongTransfer.self) { items, _ in
                                guard let transfer = items.first,
                                      let currentSourceIndex = songs.firstIndex(where: { $0.id == transfer.songId }) else {
                                    return false
                                }
                                let destIndex = index

                                if currentSourceIndex != destIndex {
                                    // Move using IndexSet API (adjusts for "insert before" semantics)
                                    let adjustedDest = destIndex > currentSourceIndex ? destIndex + 1 : destIndex
                                    songs.move(fromOffsets: IndexSet(integer: currentSourceIndex), toOffset: adjustedDest)
                                    savePlaylistOrder()
                                }
                                draggingSongId = nil
                                return true
                            } isTargeted: { isTargeted in
                                // Could add visual feedback here
                            }

                            if index < songs.count - 1 {
                                Divider()
                                    .padding(.leading, isEditing ? 62 : 50)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .task {
            await loadSongs()
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditing.toggle()
                } label: {
                    Text(isEditing ? "Done" : "Edit")
                }
            }
        }
    }

    // MARK: - Actions

    private func loadSongs() async {
        isLoading = true
        loadError = nil
        do {
            let fetchedSongs = try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            songs = appState.visibleSongsForPlayback(fetchedSongs)
            isLoading = false
        } catch let error as ResonanceError {
            loadError = error
            isLoading = false
        } catch {
            loadError = .networkUnavailable
            isLoading = false
        }
    }

    private func playSongs(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        Task {
            if shuffled {
                await appState.playbackManager.play(songs: songs.shuffled())
            } else {
                await appState.playbackManager.play(songs: songs)
            }
        }
    }

    private func savePlaylistOrder() {
        // Subsonic API doesn't support reordering directly.
        // We need to remove all songs and re-add them in the new order.
        // This is done by: remove all indexes, then add all song IDs in order.
        let originalSongs = songs  // backup for rollback
        Task {
            do {
                // First remove all songs (indexes 0 to count-1)
                let indexesToRemove = Array(0..<songs.count)
                try await appState.networkActor.updatePlaylist(
                    id: playlist.id,
                    songIndexesToRemove: indexesToRemove
                )
                // Then add them back in the new order
                try await appState.networkActor.updatePlaylist(
                    id: playlist.id,
                    songIdsToAdd: songs.map(\.id)
                )
            } catch {
                // Rollback local state on failure
                await MainActor.run {
                    songs = originalSongs
                }
                print("Failed to save playlist order: \(error)")
            }
        }
    }

    private func removeSongFromPlaylist(at index: Int) async {
        let originalSongs = songs
        songs.remove(at: index)

        do {
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIndexesToRemove: [index]
            )
        } catch {
            // Rollback on failure
            await MainActor.run {
                songs = originalSongs
            }
            print("Failed to remove song from playlist: \(error)")
        }
    }
}

struct PlaylistHeaderView: View {
    let playlist: Playlist
    let songs: [Song]
    var onPlay: () -> Void = {}
    var onShuffle: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            // Playlist art
            EnvironmentAlbumArtView(coverArtId: playlist.coverArt, size: .large)
                .frame(width: 200, height: 200)
                .cornerRadius(8)
                .shadow(radius: 10)

            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(playlist.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("\(playlist.songCount) songs")
                    Text("•")
                    Text(playlist.formattedDuration)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        onPlay()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)

                    Button {
                        onShuffle()
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(songs.isEmpty)
                }
            }

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: .placeholder)
            .environment(AppState())
    }
}
