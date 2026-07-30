import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emotionEngine) private var emotionEngine

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
                .accessibilityIdentifier("DetailView")
        }
        .mouseNavigationHandler(appState: appState)
        .navigationSplitViewStyle(.balanced)
        .onChange(of: appState.nowPlaying?.coverArt) { _, newCoverArt in
            emotionEngine.updateColors(fromArtworkId: newCoverArt, using: appState)
        }
        .onAppear {
            // Initialize emotion engine with current song if playing
            if let coverArt = appState.nowPlaying?.coverArt {
                emotionEngine.updateColors(fromArtworkId: coverArt, using: appState)
            }
        }
        .inspector(isPresented: Binding(
            get: { appState.isLyricsPanelVisible },
            set: { appState.isLyricsPanelVisible = $0 }
        )) {
            LyricsView()
                .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .inspector(isPresented: Binding(
            get: { appState.isQueueVisible },
            set: { appState.isQueueVisible = $0 }
        )) {
            ContinuePlayingPanel()
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .sheet(isPresented: Binding(
            get: { !appState.isOnboardingComplete },
            set: { if !$0 { appState.isOnboardingComplete = true } }
        )) {
            OnboardingView()
                .environment(appState)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { appState.showCreatePlaylistSheet },
            set: { appState.showCreatePlaylistSheet = $0 }
        )) {
            CreatePlaylistSheet(initialSongIds: appState.createPlaylistSongIds)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.editPlaylistTarget },
            set: { appState.editPlaylistTarget = $0 }
        )) { playlist in
            EditPlaylistSheet(playlist: playlist)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.getInfoContent },
            set: { appState.getInfoContent = $0 }
        )) { content in
            GetInfoView(content: content)
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSmartPlaylistEditor },
            set: { appState.showSmartPlaylistEditor = $0 }
        )) {
            SmartPlaylistEditorView(playlist: appState.editSmartPlaylistTarget)
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSimilarSongsSheet },
            set: { appState.showSimilarSongsSheet = $0 }
        )) {
            if let seedSong = appState.similarSongsSeedSong {
                SimilarSongsView(seedSong: seedSong)
                    .environment(appState)
            }
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(
                get: { appState.deletePlaylistTarget != nil },
                set: { if !$0 { appState.deletePlaylistTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let playlist = appState.deletePlaylistTarget {
                    Task {
                        do {
                            try await appState.networkActor.deletePlaylist(id: playlist.id)
                            await MainActor.run {
                                appState.playlists.removeAll { $0.id == playlist.id }
                                appState.deletePlaylistTarget = nil
                            }
                        } catch {
                            await MainActor.run {
                                appState.deletePlaylistTarget = nil
                            }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deletePlaylistTarget = nil
            }
        } message: {
            if let playlist = appState.deletePlaylistTarget {
                Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
            }
        }
        .globalKeyboardShortcuts()
        // MARK: - Delete Song Confirmation
        .confirmationDialog(
            "Delete from Library?",
            isPresented: Binding(
                get: { appState.deleteConfirmSong != nil },
                set: { if !$0 { appState.deleteConfirmSong = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let song = appState.deleteConfirmSong {
                    Task {
                        do {
                            try await appState.trashManager.trashSong(song)
                        } catch {
                            print("Failed to trash song: \(error)")
                        }
                        appState.deleteConfirmSong = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deleteConfirmSong = nil
            }
        } message: {
            if let song = appState.deleteConfirmSong {
                Text("Move \"\(song.title)\" by \(song.artist) to Trash?\n\nYou can undo this for 10 seconds after deletion.")
            }
        }
        // MARK: - Delete Album Confirmation
        .confirmationDialog(
            "Delete Album from Library?",
            isPresented: Binding(
                get: { appState.deleteConfirmAlbum != nil },
                set: { if !$0 { appState.deleteConfirmAlbum = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let (album, songs) = appState.deleteConfirmAlbum {
                    Task {
                        do {
                            try await appState.trashManager.trashAlbum(album, songs: songs)
                        } catch {
                            print("Failed to trash album: \(error)")
                        }
                        appState.deleteConfirmAlbum = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deleteConfirmAlbum = nil
            }
        } message: {
            if let (album, songs) = appState.deleteConfirmAlbum {
                Text("Move \"\(album.name)\" (\(songs.count) songs) to Trash?\n\nYou can undo this for 10 seconds after deletion.")
            }
        }
        // MARK: - Undo Toast
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let feedback = appState.feedback {
                    FeedbackToastView(
                        message: feedback.message,
                        detail: feedback.detail,
                        style: feedback.style,
                        systemImage: feedback.systemImage,
                        actionTitle: feedback.actionTitle,
                        action: feedback.action,
                        dismissAction: appState.dismissFeedback
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let message = appState.undoToastMessage {
                    FeedbackToastView(
                        message: message,
                        detail: nil,
                        style: .info,
                        systemImage: "trash",
                        actionTitle: "Undo",
                        action: appState.undoToastAction
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 80) // above the now playing bar
            .animation(.spring(duration: 0.3), value: appState.feedback?.id)
            .animation(.spring(duration: 0.3), value: appState.undoToastMessage)
        }
        // MARK: - ⌘K Command HUD (Quick Capture Command Layer)
        .overlay {
            if appState.isCommandHUDVisible {
                ZStack(alignment: .top) {
                    // Scrim: dim everything, click outside to close.
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { appState.isCommandHUDVisible = false }
                    CommandHUDView()
                        .padding(.top, 110)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: appState.isCommandHUDVisible)
    }
}


struct DetailView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoadingNavigation = false

    var body: some View {
        @Bindable var state = appState

        NavigationStack(path: $state.detailNavigationPath) {
            Group {
                switch appState.selectedSidebarItem {
                case .listen:
                    ListenView()
                case .plane:
                    PlaneView()
                case .home:
                    HomeView()
                case .waitingRoom:
                    WaitingRoomView()
                case .projects:
                    ProjectsView()
                case .unclassified:
                    UnclassifiedView()
                case .importPolicies:
                    ImportPoliciesView()
                case .fetcherSources:
                    FetcherSourcesView()
                case .artists:
                    ArtistsView()
                case .albums:
                    AlbumsView()
                case .songs:
                    SongsView()
                case .genres:
                    GenresView()
                case .folders:
                    FoldersView()
                case .favorites:
                    LikedSongsView()
                case .newMusic:
                    DiscoveryFeedView()
                case .recentlyAdded:
                    RecentlyAddedView()
                case .recentlyPlayed:
                    RecentlyPlayedView()
                case .downloads:
                    DownloadsView()
                case .playlists:
                    PlaylistsView()
                case .radio:
                    RadioView()
                case .search:
                    SearchView()
                }
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artist: artist)
            }
            .navigationDestination(for: Genre.self) { genre in
                GenreDetailView(genre: genre)
            }
            .navigationDestination(for: MusicFolder.self) { folder in
                FolderDetailView(folder: folder)
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: SmartPlaylist.self) { smartPlaylist in
                SmartPlaylistDetailView(playlist: smartPlaylist)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // Loading indicator while fetching data for navigation
            if isLoadingNavigation {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoadingNavigation)
        .onChange(of: appState.selectedSidebarItem) { oldValue, newValue in
            // Only clear path if NOT a deep link navigation (no pending targets)
            if appState.navigationTargetAlbumId == nil && appState.navigationTargetArtistId == nil {
                appState.detailNavigationPath = NavigationPath()
            }
        }
        .onChange(of: appState.navigationTargetAlbumId) { _, albumId in
            handleAlbumNavigation(albumId)
        }
        .onChange(of: appState.navigationTargetArtistId) { _, artistId in
            handleArtistNavigation(artistId)
        }
        // Retry navigation when albums load (handles race condition)
        .onChange(of: appState.albums) { _, _ in
            if appState.navigationTargetAlbumId != nil {
                handleAlbumNavigation(appState.navigationTargetAlbumId)
            }
        }
        // Retry navigation when artists load (handles race condition)
        .onChange(of: appState.artists) { _, _ in
            if appState.navigationTargetArtistId != nil {
                handleArtistNavigation(appState.navigationTargetArtistId)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBarInset()
        }
    }

    private func handleAlbumNavigation(_ albumId: String?) {
        guard let albumId else {
            isLoadingNavigation = false
            return
        }

        // Find album in loaded albums
        if let album = appState.albums.first(where: { $0.id == albumId }) {
            // Found - navigate
            Task { @MainActor in
                // Clear path first if we're on a different section
                if appState.selectedSidebarItem != .albums {
                    appState.detailNavigationPath = NavigationPath()
                }
                // Small delay to let NavigationStack settle after sidebar change
                try? await Task.sleep(for: .milliseconds(50))
                appState.detailNavigationPath.append(album)
                appState.navigationTargetAlbumId = nil
                isLoadingNavigation = false
            }
        } else if appState.albums.isEmpty {
            // Albums not loaded yet - trigger fetch and show loading
            isLoadingNavigation = true
            Task {
                do {
                    let albums = try await appState.networkActor.fetchAllAlbums().albums
                    await MainActor.run {
                        appState.albums = albums
                        // onChange handler will retry navigation automatically
                    }
                } catch {
                    // Fetch failed - clear pending navigation
                    await MainActor.run {
                        appState.navigationTargetAlbumId = nil
                        isLoadingNavigation = false
                    }
                }
            }
        } else {
            // Albums loaded but album not found - clear after brief timeout
            // (album may have been deleted from server)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    if appState.navigationTargetAlbumId == albumId {
                        appState.navigationTargetAlbumId = nil
                        isLoadingNavigation = false
                    }
                }
            }
        }
    }

    private func handleArtistNavigation(_ artistId: String?) {
        guard let artistId else {
            isLoadingNavigation = false
            return
        }

        // Find artist in loaded artists
        if let artist = appState.artists.first(where: { $0.id == artistId }) {
            // Found - navigate
            Task { @MainActor in
                // Clear path first if we're on a different section
                if appState.selectedSidebarItem != .artists {
                    appState.detailNavigationPath = NavigationPath()
                }
                // Small delay to let NavigationStack settle after sidebar change
                try? await Task.sleep(for: .milliseconds(50))
                appState.detailNavigationPath.append(artist)
                appState.navigationTargetArtistId = nil
                isLoadingNavigation = false
            }
        } else if appState.artists.isEmpty {
            // Artists not loaded yet - trigger fetch and show loading
            isLoadingNavigation = true
            Task {
                do {
                    let artists = try await appState.networkActor.fetchArtists()
                    await MainActor.run {
                        appState.artists = artists
                        // onChange handler will retry navigation automatically
                    }
                } catch {
                    // Fetch failed - clear pending navigation
                    await MainActor.run {
                        appState.navigationTargetArtistId = nil
                        isLoadingNavigation = false
                    }
                }
            }
        } else {
            // Artists loaded but artist not found - clear after brief timeout
            // (artist may have been deleted from server)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    if appState.navigationTargetArtistId == artistId {
                        appState.navigationTargetArtistId = nil
                        isLoadingNavigation = false
                    }
                }
            }
        }
    }
}

private struct NowPlayingBarInset: View {
    var body: some View {
        // No GeometryReader and no fixed height: the bar's intrinsic height
        // (54pt) plus the padding below measures deterministically, so the
        // safe-area inset reserves exactly the space the bar occupies.
        NowPlayingBar()
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
