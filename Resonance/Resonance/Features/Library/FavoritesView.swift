import SwiftUI

struct FavoritesView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: FavoriteTab = .songs
    @State private var viewState: ViewState = .loading

    // Data
    @State private var favoriteSongs: [Song] = []
    @State private var favoriteAlbums: [Album] = []
    @State private var favoriteArtists: [Artist] = []

    // Selection
    @State private var songSelection = Set<String>()
    @State private var selectedAlbum: Album?
    @State private var selectedArtist: Artist?

    // Loading state for playback
    @State private var isLoadingForPlayback = false

    enum ViewState {
        case loading
        case empty
        case error
        case populated
    }

    enum FavoriteTab: String, CaseIterable {
        case songs = "Songs"
        case albums = "Albums"
        case artists = "Artists"

        var icon: String {
            switch self {
            case .songs: return "music.note"
            case .albums: return "square.stack"
            case .artists: return "music.mic"
            }
        }
    }

    private var isEmpty: Bool {
        switch selectedTab {
        case .songs: return favoriteSongs.isEmpty
        case .albums: return favoriteAlbums.isEmpty
        case .artists: return favoriteArtists.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                Text("Favorites")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                // Playback menu
                Menu {
                    Button {
                        Task { await playFavorites() }
                    } label: {
                        Label("Play All", systemImage: "play")
                    }
                    .disabled(isEmpty)

                    Button {
                        Task { await playFavorites(shuffled: true) }
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Tab picker
            Picker("Category", selection: $selectedTab) {
                ForEach(FavoriteTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            // Content
            Group {
                switch viewState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .error:
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Failed to Load Favorites")
                            .font(.headline)
                        Button("Retry") {
                            Task {
                                await loadFavorites()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .empty, .populated:
                    if isEmpty {
                        emptyView
                    } else {
                        contentView
                    }
                }
            }
            .overlay {
                if isLoadingForPlayback {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading songs...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .navigationTitle("")
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist)
        }
        .task {
            await loadFavorites()
        }
        .onChange(of: selectedTab) {
            Task {
                await loadFavorites()
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        let (title, description, icon) = emptyStateContent
        ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text(description)
        )
    }

    private var emptyStateContent: (String, String, String) {
        switch selectedTab {
        case .songs:
            return ("No Favorite Songs", "Songs you love will appear here", "heart")
        case .albums:
            return ("No Favorite Albums", "Albums you love will appear here", "heart")
        case .artists:
            return ("No Favorite Artists", "Artists you love will appear here", "heart")
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .songs:
            FavoriteSongsContent(
                songs: favoriteSongs,
                selection: $songSelection
            )

        case .albums:
            FavoriteAlbumsContent(
                albums: favoriteAlbums,
                selectedAlbum: $selectedAlbum
            )

        case .artists:
            FavoriteArtistsContent(
                artists: favoriteArtists,
                selectedArtist: $selectedArtist
            )
        }
    }

    private func loadFavorites() async {
        guard let serverId = appState.activeServerId else {
            viewState = .error
            return
        }

        // Cache-first: load from GRDB instantly (sorted by starred_at DESC)
        if let cachedSongs = try? appState.databaseManager.loadStarredSongs(serverId: serverId),
           let cachedAlbums = try? appState.databaseManager.loadStarredAlbums(serverId: serverId),
           let cachedArtists = try? appState.databaseManager.loadStarredArtists(serverId: serverId),
           !cachedSongs.isEmpty || !cachedAlbums.isEmpty || !cachedArtists.isEmpty {
            applyFavoriteVisibility(
                songs: cachedSongs,
                albums: cachedAlbums,
                artists: cachedArtists,
                serverId: serverId
            )
            viewState = .populated
        } else {
            viewState = .loading
        }

        // Background sync: fetch from API + reconcile with GRDB
        do {
            let starred = try await appState.networkActor.fetchStarred2()

            // Save songs to cached_songs so JOIN queries work
            try? appState.databaseManager.saveSongs(starred.songs, serverId: serverId)

            // Reconcile starred_items with API truth
            try? appState.databaseManager.syncStarredFromAPI(
                songs: starred.songs,
                albums: starred.albums,
                artists: starred.artists,
                serverId: serverId
            )

            // Reload from GRDB for consistent starred_at DESC ordering
            applyFavoriteVisibility(
                songs: (try? appState.databaseManager.loadStarredSongs(serverId: serverId)) ?? starred.songs,
                albums: (try? appState.databaseManager.loadStarredAlbums(serverId: serverId)) ?? starred.albums,
                artists: (try? appState.databaseManager.loadStarredArtists(serverId: serverId)) ?? starred.artists,
                serverId: serverId
            )
            viewState = .populated
        } catch {
            // If we already have cached data, keep it and don't show error
            if viewState != .populated {
                print("Failed to load favorites: \(error)")
                viewState = .error
            }
        }
    }

    private func applyFavoriteVisibility(songs: [Song], albums: [Album], artists: [Artist], serverId: String) {
        let hiddenAlbumIds = loadHiddenIds(type: "album", serverId: serverId, fallback: appState.hiddenAlbumIds)
        let hiddenArtistIds = loadHiddenIds(type: "artist", serverId: serverId, fallback: appState.hiddenArtistIds)

        favoriteSongs = appState.visibleSongsForPlayback(songs, serverId: serverId)
        favoriteAlbums = albums.filter {
            !hiddenAlbumIds.contains($0.id) &&
            !hiddenArtistIds.contains($0.artistId)
        }
        favoriteArtists = artists.filter { !hiddenArtistIds.contains($0.id) }
    }

    private func loadHiddenIds(type: String, serverId: String, fallback: Set<String>) -> Set<String> {
        (try? appState.databaseManager.loadHiddenIds(type: type, serverId: serverId)) ?? fallback
    }

    private func playFavorites(shuffled: Bool = false) async {
        var songs: [Song]

        switch selectedTab {
        case .songs:
            songs = appState.visibleSongsForPlayback(favoriteSongs)

        case .albums:
            // Show loading for multi-album fetch
            isLoadingForPlayback = true
            defer { isLoadingForPlayback = false }

            // Fetch songs from all favorite albums
            var allSongs: [Song] = []
            for album in favoriteAlbums {
                do {
                    let albumSongs = try await appState.playableAlbumSongs(for: album)
                    allSongs.append(contentsOf: albumSongs)
                } catch {
                    print("Failed to fetch songs for album \(album.name): \(error)")
                }
            }
            songs = allSongs

        case .artists:
            // Show loading for multi-artist fetch
            isLoadingForPlayback = true
            defer { isLoadingForPlayback = false }

            // Fetch songs from all favorite artists
            var allSongs: [Song] = []
            for artist in favoriteArtists {
                do {
                    allSongs.append(contentsOf: try await appState.playableArtistSongs(for: artist))
                } catch {
                    print("Failed to fetch songs for artist \(artist.name): \(error)")
                }
            }
            songs = allSongs
        }

        if shuffled {
            songs.shuffle()
        }

        if !songs.isEmpty {
            await appState.playbackManager.play(songs: songs)
        }
    }
}

// MARK: - Songs Content

private struct FavoriteSongsContent: View {
    @Environment(AppState.self) private var appState
    let songs: [Song]
    @Binding var selection: Set<String>

    var body: some View {
        Table(songs, selection: $selection) {
            TableColumn("") { song in
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            .width(30)

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
    }
}

// MARK: - Albums Content

private struct FavoriteAlbumsContent: View {
    let albums: [Album]
    @Binding var selectedAlbum: Album?

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    AlbumCard(album: album)
                        .onTapGesture {
                            selectedAlbum = album
                        }
                        .contextMenu {
                            AlbumContextMenu(album: album)
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(4)
                        }
                }
            }
            .padding()
        }
    }
}

// MARK: - Artists Content

private struct FavoriteArtistsContent: View {
    let artists: [Artist]
    @Binding var selectedArtist: Artist?

    var body: some View {
        List(selection: $selectedArtist) {
            ForEach(artists) { artist in
                HStack(spacing: 12) {
                    EnvironmentAlbumArtView(coverArtId: artist.coverArt, size: .small)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name)
                            .font(.body)

                        Text("\(artist.albumCount) albums")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                .padding(.vertical, 4)
                .tag(artist)
                .contextMenu {
                    ArtistContextMenu(artist: artist)
                }
            }
        }
        .listStyle(.inset)
    }
}

#Preview {
    NavigationStack {
        FavoritesView()
            .environment(AppState())
    }
}
