import SwiftUI

struct PlaylistContextMenu: View {
    @Environment(AppState.self) private var appState
    let playlist: Playlist

    var body: some View {
        // Playback
        Group {
            Button {
                Task {
                    await playPlaylist()
                }
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                Task {
                    await playPlaylistShuffled()
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }

            Button {
                Task {
                    await addPlaylistToQueue()
                }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        }

        Divider()

        // Edit
        Button {
            appState.editPlaylistTarget = playlist
        } label: {
            Label("Edit Playlist", systemImage: "pencil")
        }

        Divider()

        // Download
        Group {
            Button {
                Task {
                    await downloadPlaylist()
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }

            Button {
                Task {
                    await removePlaylistDownload()
                }
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }

        Divider()

        // Pin
        Button {
            togglePin()
        } label: {
            Label(
                appState.isPinned(id: playlist.id, type: .playlist) ? "Unpin" : "Pin to Sidebar",
                systemImage: appState.isPinned(id: playlist.id, type: .playlist) ? "pin.slash" : "pin"
            )
        }

        Divider()

        // Get Info
        Button {
            appState.getInfoContent = .playlist(playlist)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Divider()

        // Share
        ShareMenu(content: .playlist(playlist))

        Divider()

        // Delete (triggers confirmation dialog in parent view)
        Button(role: .destructive) {
            appState.deletePlaylistTarget = playlist
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func playPlaylist() async {
        do {
            let songs = appState.visibleSongsForPlayback(
                try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            )
            await appState.playbackManager.play(songs: songs)
        } catch {
            // Handle error
        }
    }

    private func playPlaylistShuffled() async {
        do {
            let songs = appState.visibleSongsForPlayback(
                try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            )
            await appState.playbackManager.play(songs: songs.shuffled())
        } catch {
            // Handle error
        }
    }

    private func addPlaylistToQueue() async {
        do {
            let songs = appState.visibleSongsForPlayback(
                try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            )
            appState.playbackManager.addToQueue(songs)
        } catch {
            // Handle error
        }
    }

    private func downloadPlaylist() async {
        guard let server = await appState.networkActor.activeServer else { return }

        do {
            // Fetch all songs and queue them for download (async-friendly batch download)
            let songs = appState.visibleSongsForPlayback(
                try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            )
            await appState.cacheActor.queueDownloads(songs: songs, serverId: server.id)
        } catch {
            print("Failed to download playlist: \(error)")
        }
    }

    private func removePlaylistDownload() async {
        guard let server = await appState.networkActor.activeServer else { return }

        do {
            // Fetch all songs and remove each from cache via CacheActor
            let songs = try await appState.networkActor.fetchPlaylistSongs(playlistId: playlist.id)
            for song in songs {
                await appState.cacheActor.deleteDownload(songId: song.id, serverId: server.id)
            }
        } catch {
            print("Failed to remove playlist download: \(error)")
        }
    }

    private func togglePin() {
        if appState.isPinned(id: playlist.id, type: .playlist) {
            appState.unpinPlaylist(playlist)
        } else {
            appState.pinPlaylist(playlist)
        }
    }
}

#Preview {
    Text("Right click me")
        .contextMenu {
            PlaylistContextMenu(playlist: .placeholder)
        }
        .environment(AppState())
}
