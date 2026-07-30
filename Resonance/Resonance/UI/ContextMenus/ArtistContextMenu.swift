import SwiftUI

struct ArtistContextMenu: View {
    @Environment(AppState.self) private var appState
    let artist: Artist
    @State private var artistIsHidden = false
    @State private var artistIsLiked = false

    var body: some View {
        // Playback
        Group {
            Button {
                Task {
                    await playArtist()
                }
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                Task {
                    await playArtistShuffled()
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }

            Button {
                Task {
                    await addArtistToQueue()
                }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        }

        Divider()

        // Playlists
        Menu {
            ForEach(appState.playlists) { playlist in
                Button {
                    Task {
                        await addArtistToPlaylist(playlist)
                    }
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }

            Divider()

            Button {
                Task {
                    await createPlaylistWithArtistSongs()
                }
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        // Radio
        Button {
            Task {
                await startArtistRadio()
            }
        } label: {
            Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Divider()

        // Pin
        Button {
            togglePin()
        } label: {
            Label(
                appState.isPinned(id: artist.id, type: .artist) ? "Unpin" : "Pin to Sidebar",
                systemImage: appState.isPinned(id: artist.id, type: .artist) ? "pin.slash" : "pin"
            )
        }

        Divider()

        // Info & Actions
        Group {
            Button {
                appState.getInfoContent = .artist(artist)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Button {
                toggleLike()
            } label: {
                Label(artistIsLiked ? "Remove from Liked" : "Like", systemImage: artistIsLiked ? "plus.circle.fill" : "plus.circle")
            }

            Button {
                toggleLove()
            } label: {
                Label(artist.starred != nil ? "Remove from Loved" : "Love", systemImage: artist.starred != nil ? "heart.fill" : "heart")
            }

            Button {
                toggleHide()
            } label: {
                Label(artistIsHidden ? "Unhide" : "Hide", systemImage: artistIsHidden ? "eye" : "eye.slash")
            }

            // Share
            ShareMenu(content: .artist(artist))
        }
        .task {
            if let serverId = appState.activeServerId {
                artistIsHidden = (try? appState.databaseManager.isHidden(id: artist.id, type: "artist", serverId: serverId)) ?? false
                artistIsLiked = (try? appState.databaseManager.isLiked(id: artist.id, type: "artist", serverId: serverId)) ?? false
            }
        }
    }

    // MARK: - Actions

    private func playArtist() async {
        do {
            let songs = try await fetchArtistSongs()
            await appState.playbackManager.play(songs: songs)
        } catch {
            // Handle error
        }
    }

    private func playArtistShuffled() async {
        do {
            let songs = try await fetchArtistSongs()
            await appState.playbackManager.play(songs: songs.shuffled())
        } catch {
            // Handle error
        }
    }

    private func addArtistToQueue() async {
        do {
            let songs = try await fetchArtistSongs()
            appState.playbackManager.addToQueue(songs)
        } catch {
            // Handle error
        }
    }

    private func startArtistRadio() async {
        do {
            let songs = appState.visibleSongsForPlayback(
                try await appState.networkActor.getSimilarSongs(id: artist.id, count: 50)
            )
            await appState.playbackManager.play(songs: songs.shuffled())
        } catch {
            // Handle error
        }
    }

    private func fetchArtistSongs() async throws -> [Song] {
        try await appState.playableArtistSongs(for: artist)
    }

    private func addArtistToPlaylist(_ playlist: Playlist) async {
        do {
            let songs = try await fetchArtistSongs()
            let songIds = songs.map { $0.id }
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: songIds
            )
        } catch {
            print("Failed to add artist to playlist: \(error)")
        }
    }

    private func createPlaylistWithArtistSongs() async {
        do {
            let songs = try await fetchArtistSongs()
            await MainActor.run {
                appState.createPlaylistSongIds = songs.map { $0.id }
                appState.showCreatePlaylistSheet = true
            }
        } catch {
            print("Failed to fetch artist songs for playlist: \(error)")
        }
    }

    private func toggleLike() {
        guard let serverId = appState.activeServerId else { return }
        do {
            if artistIsLiked {
                try appState.databaseManager.unlikeItem(id: artist.id, type: "artist", serverId: serverId)
                artistIsLiked = false
            } else {
                try appState.databaseManager.likeItem(id: artist.id, type: "artist", serverId: serverId)
                artistIsLiked = true
            }
            appState.refreshLikedIds()
        } catch {
            print("Failed to toggle like: \(error)")
        }
    }

    private func toggleLove() {
        Task {
            do {
                if artist.starred != nil {
                    try await appState.networkActor.unstar(id: artist.id, type: .artist)
                    appState.updateArtistStarred(id: artist.id, starred: nil)
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.unstarItem(id: artist.id, type: "artist", serverId: serverId)
                    }
                } else {
                    let now = Date()
                    try await appState.networkActor.star(id: artist.id, type: .artist)
                    appState.updateArtistStarred(id: artist.id, starred: now)
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.starItem(id: artist.id, type: "artist", serverId: serverId, starredAt: now)
                    }
                }
            } catch {
                // API call failed, don't update local state
            }
        }
    }

    private func toggleHide() {
        guard let serverId = appState.activeServerId else { return }
        do {
            if artistIsHidden {
                try appState.databaseManager.unhideItem(id: artist.id, type: "artist", serverId: serverId)
                artistIsHidden = false
                // Re-add to runtime array if not already present
                if !appState.artists.contains(where: { $0.id == artist.id }) {
                    appState.artists.append(artist)
                    appState.artists.sort { $0.name < $1.name }
                }
            } else {
                try appState.databaseManager.hideItem(id: artist.id, type: "artist", serverId: serverId)
                artistIsHidden = true
                // Remove from runtime array immediately
                appState.artists.removeAll { $0.id == artist.id }
            }
            appState.refreshHiddenIds()
        } catch {
            print("Failed to toggle hide: \(error)")
        }
    }

    private func togglePin() {
        if appState.isPinned(id: artist.id, type: .artist) {
            appState.unpinArtist(artist)
        } else {
            appState.pinArtist(artist)
        }
    }
}

#Preview {
    Text("Right click me")
        .contextMenu {
            ArtistContextMenu(artist: .placeholder)
        }
        .environment(AppState())
}
