import SwiftUI
import AppKit

struct SongContextMenu: View {
    @Environment(AppState.self) private var appState
    let song: Song
    @State private var cachedFilePath: URL?
    @State private var songIsHidden = false
    @State private var songIsLiked = false

    var body: some View {
        // Playback
        Group {
            Button {
                Task {
                    await appState.playbackManager.playNow(song)
                }
            } label: {
                Label("Play Now", systemImage: "play")
            }

            Button {
                appState.playbackManager.playNext(song)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                appState.playbackManager.addToQueue(song)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }

            Button {
                appState.similarSongsSeedSong = song
                appState.showSimilarSongsSheet = true
            } label: {
                Label("Start Station", systemImage: "dot.radiowaves.left.and.right")
            }
        }

        Divider()

        // Playlists
        Menu {
            ForEach(appState.playlists) { playlist in
                Button {
                    Task {
                        await addToPlaylist(song, playlist: playlist)
                    }
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }

            Divider()

            Button {
                appState.createPlaylistSongIds = [song.id]
                appState.showCreatePlaylistSheet = true
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        // Navigation
        Group {
            if !song.albumId.isEmpty {
                Button {
                    navigateToAlbum(song.albumId)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if !song.artistId.isEmpty {
                Button {
                    navigateToArtist(song.artistId)
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }

        Divider()

        // Info & Actions
        Group {
            QuickCaptureMenu(song: song)

            Button {
                appState.getInfoContent = .song(song)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Button {
                toggleLike(song)
            } label: {
                Label(songIsLiked ? "Remove from Liked" : "Like", systemImage: songIsLiked ? "plus.circle.fill" : "plus.circle")
            }

            Button {
                toggleLove(song)
            } label: {
                Label(song.starred != nil ? "Remove from Loved" : "Love", systemImage: song.starred != nil ? "heart.fill" : "heart")
            }

            Button {
                toggleHide(song)
            } label: {
                Label(songIsHidden ? "Unhide" : "Hide", systemImage: songIsHidden ? "eye" : "eye.slash")
            }

            // Rating picker
            RatingPicker(currentRating: song.rating) { newRating in
                setRating(song, rating: newRating)
            }

            // Download actions
            if cachedFilePath != nil {
                Button {
                    if let path = cachedFilePath {
                        NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: "")
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button(role: .destructive) {
                    Task {
                        await removeDownload(song)
                    }
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else {
                Button {
                    Task {
                        await downloadSong(song)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }

            // Share
            ShareMenu(content: .song(song))

            Divider()

            Button(role: .destructive) {
                appState.deleteConfirmSong = song
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
        }
        .task {
            await updateCachedFilePath()
            if let serverId = appState.activeServerId {
                songIsHidden = (try? appState.databaseManager.isHidden(id: song.id, type: "song", serverId: serverId)) ?? false
                songIsLiked = (try? appState.databaseManager.isLiked(id: song.id, type: "song", serverId: serverId)) ?? false
            }
        }
    }

    // MARK: - Actions

    private func updateCachedFilePath() async {
        guard let server = await appState.networkActor.activeServer else {
            cachedFilePath = nil
            return
        }

        cachedFilePath = await appState.cacheActor.getDownloadedAudioPath(
            for: song.id,
            serverId: server.id,
            preferredSuffix: song.suffix
        )
    }

    private func addToPlaylist(_ song: Song, playlist: Playlist) async {
        do {
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: [song.id]
            )
        } catch {
            print("Failed to add song to playlist: \(error)")
        }
    }

    private func navigateToAlbum(_ albumId: String) {
        // Set navigation target and switch to albums view
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    private func navigateToArtist(_ artistId: String) {
        // Set navigation target and switch to artists view
        appState.navigationTargetArtistId = artistId
        appState.selectedSidebarItem = .artists
    }

    private func toggleLove(_ song: Song) {
        Task {
            do {
                if song.starred != nil {
                    try await appState.networkActor.unstar(id: song.id, type: .song)
                    appState.updateSongStarred(id: song.id, starred: nil)
                    // Parallel db write
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.unstarItem(id: song.id, type: "song", serverId: serverId)
                    }
                } else {
                    let now = Date()
                    try await appState.networkActor.star(id: song.id, type: .song)
                    appState.updateSongStarred(id: song.id, starred: now)
                    // Parallel db write
                    if let serverId = appState.activeServerId {
                        try? appState.databaseManager.starItem(id: song.id, type: "song", serverId: serverId, starredAt: now)
                    }
                }
            } catch {
                // API call failed, don't update local state
            }
        }
    }

    private func toggleLike(_ song: Song) {
        guard let serverId = appState.activeServerId else { return }

        let shouldLike = !songIsLiked
        let likedAt = Date()

        do {
            if shouldLike {
                // Keep the liked-songs sidecar queryable offline even if this song was fetched ad hoc.
                try appState.databaseManager.saveSongs([song], serverId: serverId)
                try appState.databaseManager.likeItem(
                    id: song.id,
                    type: "song",
                    serverId: serverId,
                    likedAt: likedAt,
                    source: "manual"
                )
                songIsLiked = true
            } else {
                try appState.databaseManager.unlikeItem(id: song.id, type: "song", serverId: serverId)
                songIsLiked = false
            }
            appState.refreshLikedIds()
        } catch {
            print("Failed to toggle like: \(error)")
            return
        }

        guard appState.connectionStatus == .connected else {
            return
        }

        Task {
            do {
                if shouldLike {
                    try await appState.networkActor.star(id: song.id, type: .song)
                    try? appState.databaseManager.starItem(
                        id: song.id,
                        type: "song",
                        serverId: serverId,
                        starredAt: likedAt
                    )
                    appState.updateSongStarred(id: song.id, starred: likedAt)
                } else {
                    try await appState.networkActor.unstar(id: song.id, type: .song)
                    try? appState.databaseManager.unstarItem(id: song.id, type: "song", serverId: serverId)
                    appState.updateSongStarred(id: song.id, starred: nil)
                }
            } catch {
                print("Failed to mirror liked song to Navidrome star state: \(error)")
            }
        }
    }

    private func toggleHide(_ song: Song) {
        guard let serverId = appState.activeServerId else { return }
        do {
            if songIsHidden {
                try appState.databaseManager.unhideItem(id: song.id, type: "song", serverId: serverId)
                songIsHidden = false
            } else {
                try appState.databaseManager.hideItem(id: song.id, type: "song", serverId: serverId)
                songIsHidden = true
            }
            appState.refreshHiddenIds()
        } catch {
            print("Failed to toggle hide: \(error)")
        }
    }

    private func setRating(_ song: Song, rating: Int) {
        let previousRating = song.rating
        let newRating = rating == 0 ? nil : rating

        // Optimistic update
        appState.updateSongRating(id: song.id, rating: newRating)

        Task {
            do {
                try await appState.networkActor.setRating(id: song.id, rating: rating)
            } catch {
                // Revert on failure
                appState.updateSongRating(id: song.id, rating: previousRating)
            }
        }
    }

    private func downloadSong(_ song: Song) async {
        guard let server = await appState.networkActor.activeServer else { return }

        // Queue the download - CacheActor handles the actual downloading
        await appState.cacheActor.queueDownload(song: song, serverId: server.id)
    }

    private func removeDownload(_ song: Song) async {
        guard let server = await appState.networkActor.activeServer else { return }

        // Delete the download and its metadata
        await appState.cacheActor.deleteDownload(songId: song.id, serverId: server.id)
        cachedFilePath = nil
    }
}

#Preview {
    Text("Right click me")
        .contextMenu {
            SongContextMenu(song: .placeholder)
        }
        .environment(AppState())
}
