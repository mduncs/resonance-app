import SwiftUI

/// Context menu for operations on multiple songs at once.
struct BulkSongContextMenu: View {
    @Environment(AppState.self) private var appState
    private let songs: [Song]
    private let selectedCount: Int
    private let expectedServerID: String?
    private let songProvider: (@MainActor () async throws -> [Song])?
    @State private var isResolving = false
    @State private var resolutionError: String?

    init(songs: [Song]) {
        self.songs = songs
        self.selectedCount = songs.count
        self.expectedServerID = nil
        self.songProvider = nil
    }

    init(
        selectedCount: Int,
        expectedServerID: String? = nil,
        songProvider: @escaping @MainActor () async throws -> [Song]
    ) {
        self.songs = []
        self.selectedCount = selectedCount
        self.expectedServerID = expectedServerID
        self.songProvider = songProvider
    }

    var body: some View {
        if isResolving {
            Label("Preparing \(selectedCount) songs…", systemImage: "progress.indicator")
                .disabled(true)
        } else if let resolutionError {
            Label(resolutionError, systemImage: "exclamationmark.triangle")
                .disabled(true)
            Divider()
        }

        // Playback
        Group {
            Button {
                Task {
                    await withResolvedSongs { songs, _ in
                        await appState.playbackManager.play(songs: visibleSongs(from: songs))
                    }
                }
            } label: {
                Label("Play All (\(actionCount))", systemImage: "play")
            }
            .disabled(actionCount == 0 || isResolving)

            Button {
                Task {
                    await withResolvedSongs { songs, _ in
                        var shuffled = visibleSongs(from: songs)
                        shuffled.shuffle()
                        await appState.playbackManager.play(songs: shuffled)
                    }
                }
            } label: {
                Label("Shuffle All", systemImage: "shuffle")
            }
            .disabled(actionCount == 0 || isResolving)

            Button {
                Task {
                    await withResolvedSongs { songs, _ in
                        appState.playbackManager.addToQueue(visibleSongs(from: songs))
                    }
                }
            } label: {
                Label("Add All to Queue", systemImage: "text.badge.plus")
            }
            .disabled(actionCount == 0 || isResolving)
        }

        Divider()

        // Playlists
        PlaylistDestinationMenu(onSelect: { playlist in
            Task {
                await withResolvedSongs { songs, serverID in
                    try await addToPlaylist(songs, playlist: playlist, serverID: serverID)
                }
            }
        }, onBrowse: {
            let origin = expectedServerID ?? appState.activeServerId
            appState.choosePlaylist(itemCount: actionCount) {
                guard let origin else { throw StaleBulkAction() }
                try ensureCurrentServer(origin)
                let resolved = try await songProvider?() ?? songs
                try Task.checkCancellation()
                try ensureCurrentServer(origin)
                return visibleSongs(from: resolved).map(\.id)
            }
        }, onCreate: {
            Task {
                await withResolvedSongs { songs, serverID in
                    try ensureCurrentServer(serverID)
                    appState.createPlaylistSongIds = songs.map(\.id)
                    appState.showCreatePlaylistSheet = true
                }
            }
        })
        Divider()

        // Bulk actions
        Group {
            Button {
                Task {
                    await withResolvedSongs { songs, serverID in
                        try await loveAll(songs, serverID: serverID)
                    }
                }
            } label: {
                Label("Love All", systemImage: "heart")
            }

            Button {
                Task {
                    await withResolvedSongs { songs, serverID in
                        try await downloadAll(songs, serverID: serverID)
                    }
                }
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Actions

    private var actionCount: Int {
        // Menu construction must not synchronously reload three hidden-ID sets
        // or filter a large selection for each label/disabled check. Revalidate
        // visibility once the user actually invokes an action.
        selectedCount
    }

    private func visibleSongs(from songs: [Song]) -> [Song] {
        appState.visibleSongsForPlayback(songs)
    }

    private func withResolvedSongs(
        _ action: @escaping @MainActor ([Song], String) async throws -> Void
    ) async {
        guard !isResolving else { return }
        isResolving = true
        resolutionError = nil
        defer { isResolving = false }
        do {
            guard let serverID = expectedServerID ?? appState.activeServerId else {
                throw StaleBulkAction()
            }
            try ensureCurrentServer(serverID)
            let resolved = try await songProvider?() ?? songs
            try Task.checkCancellation()
            try ensureCurrentServer(serverID)
            guard !resolved.isEmpty else {
                throw EmptyBulkSelection()
            }
            try await action(resolved, serverID)
        } catch is CancellationError {
            return
        } catch {
            resolutionError = error.localizedDescription
            appState.showFeedback(
                message: "Couldn't complete the song action",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private struct StaleBulkAction: LocalizedError {
        var errorDescription: String? { "The active server changed. Try the action again." }
    }

    private struct EmptyBulkSelection: LocalizedError {
        var errorDescription: String? { "No selected songs are still available." }
    }

    private func ensureCurrentServer(_ serverID: String) throws {
        try Task.checkCancellation()
        guard appState.activeServerId == serverID else { throw StaleBulkAction() }
    }

    private func addToPlaylist(_ songs: [Song], playlist: Playlist, serverID: String) async throws {
        try ensureCurrentServer(serverID)
        guard let expectedServerID = UUID(uuidString: serverID) else { throw StaleBulkAction() }
        try await appState.networkActor.updatePlaylist(
            id: playlist.id,
            songIdsToAdd: songs.map { $0.id },
            expectedServerID: expectedServerID
        )
        try ensureCurrentServer(serverID)
    }

    private func loveAll(_ songs: [Song], serverID: String) async throws {
        guard let expectedServerID = UUID(uuidString: serverID) else { throw StaleBulkAction() }
        for song in songs where song.starred == nil {
            try ensureCurrentServer(serverID)
            try await appState.networkActor.star(
                id: song.id, type: .song, expectedServerID: expectedServerID
            )
            try ensureCurrentServer(serverID)
            appState.updateSongStarred(id: song.id, starred: Date())
        }
    }

    private func downloadAll(_ songs: [Song], serverID: String) async throws {
        try ensureCurrentServer(serverID)
        guard let server = await appState.networkActor.activeServer,
              server.id.uuidString == serverID else { throw StaleBulkAction() }

        for song in songs {
            try ensureCurrentServer(serverID)
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
