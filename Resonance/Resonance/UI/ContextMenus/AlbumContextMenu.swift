import SwiftUI

struct AlbumContextMenu: View {
    @Environment(AppState.self) private var appState
    let album: Album
    @State private var albumIsHidden = false
    @State private var albumIsLiked = false

    var body: some View {
        // Playback
        Group {
            Button {
                Task {
                    await playAlbum()
                }
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                Task {
                    await playAlbumShuffled()
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }

            Button {
                Task {
                    await addAlbumToQueue()
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
                        await addAlbumToPlaylist(playlist)
                    }
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }

            Divider()

            Button {
                Task {
                    await createPlaylistWithAlbumSongs()
                }
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        // Navigation
        Button {
            navigateToAlbum()
        } label: {
            Label("Go to Album", systemImage: "square.stack")
        }

        Button {
            navigateToArtist()
        } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }

        Divider()

        // Pin
        Button {
            togglePin()
        } label: {
            Label(
                appState.isPinned(id: album.id, type: .album) ? "Unpin" : "Pin to Sidebar",
                systemImage: appState.isPinned(id: album.id, type: .album) ? "pin.slash" : "pin"
            )
        }

        Divider()

        // Info & Actions
        Group {
            Button {
                appState.getInfoContent = .album(album)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Button {
                toggleLike()
            } label: {
                Label(albumIsLiked ? "Remove from Liked" : "Like", systemImage: albumIsLiked ? "plus.circle.fill" : "plus.circle")
            }

            Button {
                toggleLove()
            } label: {
                Label(album.starred != nil ? "Remove from Loved" : "Love", systemImage: album.starred != nil ? "heart.fill" : "heart")
            }

            Button {
                toggleHide()
            } label: {
                Label(albumIsHidden ? "Unhide" : "Hide", systemImage: albumIsHidden ? "eye" : "eye.slash")
            }

            // Rating picker
            RatingPicker(currentRating: album.rating) { newRating in
                setRating(newRating)
            }

            // Download
            Menu {
                Button {
                    Task {
                        await downloadAlbum()
                    }
                } label: {
                    Label("Download Album", systemImage: "arrow.down.circle")
                }

                Button(role: .destructive) {
                    Task {
                        await removeAlbumDownload()
                    }
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }

            // Share
            ShareMenu(content: .album(album))

            Divider()

            Button(role: .destructive) {
                Task {
                    do {
                        let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                        appState.deleteConfirmAlbum = (album: album, songs: songs)
                    } catch {
                        print("Failed to fetch album songs for delete: \(error)")
                    }
                }
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
        }
        .task {
            if let serverId = appState.activeServerId {
                albumIsHidden = (try? appState.databaseManager.isHidden(id: album.id, type: "album", serverId: serverId)) ?? false
                albumIsLiked = (try? appState.databaseManager.isLiked(id: album.id, type: "album", serverId: serverId)) ?? false
            }
        }
    }

    // MARK: - Actions

    private func playAlbum() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs)
        } catch {
            print("Failed to play album '\(album.name)': \(error.localizedDescription)")
        }
    }

    private func playAlbumShuffled() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs.shuffled())
        } catch {
            print("Failed to shuffle album '\(album.name)': \(error.localizedDescription)")
        }
    }

    private func addAlbumToQueue() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            appState.playbackManager.addToQueue(songs)
        } catch {
            print("Failed to add album '\(album.name)' to queue: \(error.localizedDescription)")
        }
    }

    private func addAlbumToPlaylist(_ playlist: Playlist) async {
        do {
            // Fetch all songs in the album and add them to the playlist
            let songs = try await appState.playableAlbumSongs(for: album)
            let songIds = songs.map { $0.id }
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: songIds
            )
        } catch {
            print("Failed to add album to playlist: \(error)")
        }
    }

    private func createPlaylistWithAlbumSongs() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await MainActor.run {
                appState.createPlaylistSongIds = songs.map { $0.id }
                appState.showCreatePlaylistSheet = true
            }
        } catch {
            print("Failed to fetch album songs for playlist: \(error)")
        }
    }

    private func navigateToAlbum() {
        // Set navigation target and switch to albums view
        appState.navigationTargetAlbumId = album.id
        appState.selectedSidebarItem = .albums
    }

    private func navigateToArtist() {
        // Set navigation target and switch to artists view
        appState.navigationTargetArtistId = album.artistId
        appState.selectedSidebarItem = .artists
    }

    private func toggleLike() {
        guard let serverId = appState.activeServerId else { return }
        do {
            if albumIsLiked {
                try appState.databaseManager.unlikeItem(id: album.id, type: "album", serverId: serverId)
                albumIsLiked = false
            } else {
                try appState.databaseManager.likeItem(id: album.id, type: "album", serverId: serverId)
                albumIsLiked = true
            }
            appState.refreshLikedIds()
        } catch {
            print("Failed to toggle like: \(error)")
        }
    }

    private func toggleLove() {
        Task {
            do {
                if album.starred != nil {
                    try await appState.networkActor.unstar(id: album.id, type: .album)
                    appState.updateAlbumStarred(id: album.id, starred: nil)
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.unstarItem(id: album.id, type: "album", serverId: serverId)
                    }
                } else {
                    let now = Date()
                    try await appState.networkActor.star(id: album.id, type: .album)
                    appState.updateAlbumStarred(id: album.id, starred: now)
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.starItem(id: album.id, type: "album", serverId: serverId, starredAt: now)
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
            if albumIsHidden {
                try appState.databaseManager.unhideItem(id: album.id, type: "album", serverId: serverId)
                albumIsHidden = false
                // Re-add to runtime array if not already present
                if !appState.albums.contains(where: { $0.id == album.id }) {
                    appState.albums.append(album)
                    appState.albums.sort { $0.name < $1.name }
                }
            } else {
                try appState.databaseManager.hideItem(id: album.id, type: "album", serverId: serverId)
                albumIsHidden = true
                // Remove from runtime array immediately
                appState.albums.removeAll { $0.id == album.id }
            }
            appState.refreshHiddenIds()
        } catch {
            print("Failed to toggle hide: \(error)")
        }
    }

    private func togglePin() {
        if appState.isPinned(id: album.id, type: .album) {
            appState.unpinAlbum(album)
        } else {
            appState.pinAlbum(album)
        }
    }

    private func setRating(_ rating: Int) {
        let previousRating = album.rating
        let newRating = rating == 0 ? nil : rating

        // Optimistic update
        appState.updateAlbumRating(id: album.id, rating: newRating)

        Task {
            do {
                try await appState.networkActor.setRating(id: album.id, rating: rating)
            } catch {
                // Revert on failure
                appState.updateAlbumRating(id: album.id, rating: previousRating)
            }
        }
    }

    private func downloadAlbum() async {
        guard let server = await appState.networkActor.activeServer else { return }

        do {
            // Fetch all songs and queue them for download
            let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
            await appState.cacheActor.queueDownloads(songs: songs, serverId: server.id)
        } catch {
            print("Failed to download album: \(error)")
        }
    }

    private func removeAlbumDownload() async {
        guard let server = await appState.networkActor.activeServer else { return }

        do {
            // Fetch all songs and remove each from cache
            let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
            for song in songs {
                await appState.cacheActor.deleteDownload(songId: song.id, serverId: server.id)
            }
        } catch {
            print("Failed to remove album download: \(error)")
        }
    }
}

#Preview {
    Text("Right click me")
        .contextMenu {
            AlbumContextMenu(album: .placeholder)
        }
        .environment(AppState())
}
