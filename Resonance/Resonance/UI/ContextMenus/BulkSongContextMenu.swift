import SwiftUI

/// Context menu for operations on multiple songs at once.
struct BulkSongContextMenu: View {
    @Environment(AppState.self) private var appState
    let songs: [Song]

    var body: some View {
        // Playback
        Group {
            Button {
                Task {
                    await appState.playbackManager.play(songs: visibleSongs)
                }
            } label: {
                Label("Play All (\(visibleSongs.count))", systemImage: "play")
            }
            .disabled(visibleSongs.isEmpty)

            Button {
                Task {
                    var shuffled = visibleSongs
                    shuffled.shuffle()
                    await appState.playbackManager.play(songs: shuffled)
                }
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }
            .disabled(visibleSongs.isEmpty)

            Button {
                appState.playbackManager.addToQueue(visibleSongs)
            } label: {
                Label("Add All to Queue", systemImage: "text.badge.plus")
            }
            .disabled(visibleSongs.isEmpty)
        }

        Divider()

        // Playlists
        Menu {
            ForEach(appState.playlists) { playlist in
                Button {
                    Task {
                        await addToPlaylist(playlist: playlist)
                    }
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }

            Divider()

            Button {
                appState.createPlaylistSongIds = songs.map { $0.id }
                appState.showCreatePlaylistSheet = true
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        // Bulk actions
        Group {
            Button {
                Task {
                    await loveAll()
                }
            } label: {
                Label("Love All", systemImage: "heart")
            }

            Button {
                Task {
                    await downloadAll()
                }
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Actions

    private var visibleSongs: [Song] {
        appState.visibleSongsForPlayback(songs)
    }

    private func addToPlaylist(playlist: Playlist) async {
        do {
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: songs.map { $0.id }
            )
        } catch {
            print("Failed to add songs to playlist: \(error)")
        }
    }

    private func loveAll() async {
        for song in songs where song.starred == nil {
            do {
                try await appState.networkActor.star(id: song.id, type: .song)
                appState.updateSongStarred(id: song.id, starred: Date())
            } catch {
                // Continue with next song on failure
            }
        }
    }

    private func downloadAll() async {
        guard let server = await appState.networkActor.activeServer else { return }

        for song in songs {
            await appState.cacheActor.queueDownload(song: song, serverId: server.id)
        }
    }
}

#Preview {
    Text("Right click me")
        .contextMenu {
            BulkSongContextMenu(songs: [.placeholder, .placeholder])
        }
        .environment(AppState())
}
