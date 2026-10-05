import SwiftUI

struct GenreDetailView: View {
    @Environment(AppState.self) private var appState
    let genre: Genre

    @State private var viewState: ViewState = .loading
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var selectedTab: ContentTab = .albums
    @State private var selectedAlbum: Album?
    @State private var songSelection = Set<String>()

    enum ViewState {
        case loading
        case empty
        case error(String)
        case populated
    }

    enum ContentTab: String, CaseIterable {
        case albums = "Albums"
        case songs = "Songs"
    }

    private let albumColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            GenreHeaderView(genre: genre, albumCount: albums.count, songCount: songs.count) {
                await playGenre()
            } onShuffle: {
                await playGenre(shuffled: true)
            }

            Divider()

            // Tab picker
            Picker("View", selection: $selectedTab) {
                ForEach(ContentTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            // Content
            Group {
                switch viewState {
                case .loading:
                    loadingView

                case .empty:
                    CompactStatusView(
                        title: "No Content",
                        systemImage: "guitars",
                        message: "No \(genre.name) music found."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let message):
                    CompactStatusView(
                        title: "Failed to Load",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadGenreContent() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    switch selectedTab {
                    case .albums:
                        albumsContent
                    case .songs:
                        songsContent
                    }
                }
            }
        }
        .navigationTitle(genre.name)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .toolbar {
            // .primaryAction keeps this trailing; without an explicit placement
            // .automatic drops it next to the back chevron, where it reads as
            // a second transport cluster competing with the floating bar.
            // Play/Shuffle live in GenreHeaderView, so they are not repeated here.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        songs.forEach { appState.playbackManager.addToQueue($0) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        songs.reversed().forEach { appState.playbackManager.playNext($0) }
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    .disabled(songs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadGenreContent()
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        switch selectedTab {
        case .albums:
            ScrollView {
                LazyVGrid(columns: albumColumns, spacing: 20) {
                    ForEach(0..<8, id: \.self) { _ in
                        AlbumCard(album: .placeholder)
                            .redacted(reason: .placeholder)
                    }
                }
                .padding()
            }

        case .songs:
            List {
                ForEach(0..<10, id: \.self) { _ in
                    SongRow(song: .placeholder)
                        .redacted(reason: .placeholder)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        ScrollView {
            LazyVGrid(columns: albumColumns, spacing: 20) {
                ForEach(albums) { album in
                    AlbumCardActionSurface(
                        album: album,
                        onPlay: { Task { await playAlbum(album) } }
                    ) { artworkHoverChanged in
                        Button {
                            selectedAlbum = album
                        } label: {
                            AlbumCard(
                                album: album,
                                showsHoverPlayButton: false,
                                onArtworkHoverChange: artworkHoverChanged
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded { Task { await playAlbum(album) } }
                        )
                    }
                    .contextMenu {
                        Button {
                            Task {
                                await playAlbum(album)
                            }
                        } label: {
                            Label("Play", systemImage: "play")
                        }

                        Button {
                            Task {
                                await playAlbum(album, shuffled: true)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }

                        Button {
                            Task {
                                await addAlbumToQueue(album)
                            }
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }

                        Divider()

                        Button {
                            selectedAlbum = album
                        } label: {
                            Label("View Album", systemImage: "square.stack")
                        }

                        Button {
                            appState.getInfoContent = .album(album)
                        } label: {
                            Label("Get Info", systemImage: "info.circle")
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var songsContent: some View {
        Table(songs, selection: $songSelection) {
            TableColumn("") { song in
                if song.starred != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
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
            let selectedSongs = songs.filter { selectedIds.contains($0.id) }
            if selectedSongs.count > 1 {
                BulkSongContextMenu(songs: selectedSongs)
            } else if let song = selectedSongs.first {
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
        .onKeyPress(.return) {
            if !songSelection.isEmpty,
               let songId = songSelection.first,
               let song = songs.first(where: { $0.id == songId }),
               let index = songs.firstIndex(of: song) {
                Task {
                    await appState.playbackManager.play(songs: songs, startingAt: index)
                }
                return .handled
            }
            return .ignored
        }
    }

    private func loadGenreContent() async {
        viewState = .loading

        do {
            let admittedAlbumIds = loadLibraryMemberIds(type: .album, fallback: appState.admittedAlbumIds)
            let hiddenAlbumIds = loadHiddenIds(type: "album", fallback: appState.hiddenAlbumIds)

            // Page through every genre song; a single request would silently
            // truncate large genres behind Subsonic's per-response cap.
            songs = try await GenreSongsFetcher.fetchAllAdmitted(appState: appState, genre: genre.name)

            // Derive unique albums from the songs
            var uniqueAlbums: [String: Album] = [:]
            for song in songs {
                if !song.albumId.isEmpty && uniqueAlbums[song.albumId] == nil {
                    uniqueAlbums[song.albumId] = Album(
                        id: song.albumId,
                        name: song.album,
                        artist: song.artist,
                        artistId: song.artistId,
                        songCount: 0,
                        duration: 0,
                        year: song.year,
                        genre: song.genre,
                        coverArt: song.coverArt,
                        starred: nil,
                        rating: nil
                    )
                }
            }
            albums = Array(uniqueAlbums.values)
                .filter { admittedAlbumIds.contains($0.id) && !hiddenAlbumIds.contains($0.id) }
                .sorted { $0.name < $1.name }

            viewState = songs.isEmpty && albums.isEmpty ? .empty : .populated
        } catch {
            print("Failed to load genre content: \(error)")
            viewState = .error(error.localizedDescription)
        }
    }

    private func playGenre(shuffled: Bool = false) async {
        var songsToPlay = songs
        if shuffled {
            songsToPlay.shuffle()
        }
        await appState.playbackManager.play(songs: songsToPlay)
    }

    private func playAlbum(_ album: Album, shuffled: Bool = false) async {
        do {
            var albumSongs = try await loadPlayableAlbumSongs(album)
            if shuffled {
                albumSongs.shuffle()
            }
            if !albumSongs.isEmpty {
                await appState.playbackManager.play(songs: albumSongs)
            }
        } catch {
            print("Failed to play album: \(error)")
        }
    }

    private func addAlbumToQueue(_ album: Album) async {
        do {
            let albumSongs = try await loadPlayableAlbumSongs(album)
            for song in albumSongs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add album to queue: \(error)")
        }
    }

    private func loadPlayableAlbumSongs(_ album: Album) async throws -> [Song] {
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        let albumSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
        return albumSongs.filter {
            admittedSongIds.contains($0.id) && !hiddenSongIds.contains($0.id)
        }
    }

    private func loadLibraryMemberIds(type: LibraryItemType, fallback: Set<String>) -> Set<String> {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.loadLibraryMemberIds(type: type, serverId: serverId)) ?? fallback
    }

    private func loadHiddenIds(type: String, fallback: Set<String>) -> Set<String> {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.loadHiddenIds(type: type, serverId: serverId)) ?? fallback
    }
}

// MARK: - Genre Header

private struct GenreHeaderView: View {
    let genre: Genre
    let albumCount: Int
    let songCount: Int
    let onPlay: () async -> Void
    let onShuffle: () async -> Void

    var body: some View {
        HStack(spacing: 24) {
            // Genre icon
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(genreGradient)
                    .frame(width: 140, height: 140)

                Image(systemName: genreIcon)
                    .font(.system(size: 50))
                    .foregroundStyle(.white)
            }
            .shadow(radius: 8)

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text("Genre")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(genre.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                HStack(spacing: 8) {
                    Text("\(albumCount) albums")
                    Text("•")
                    Text("\(songCount) songs")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        Task { await onPlay() }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await onShuffle() }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private var genreGradient: LinearGradient {
        // Different colors for different genres
        let colors: [Color] = {
            switch genre.name.lowercased() {
            case let name where name.contains("rock"):
                return [.red, .orange]
            case let name where name.contains("jazz"):
                return [.blue, .purple]
            case let name where name.contains("electronic") || name.contains("edm"):
                return [.cyan, .blue]
            case let name where name.contains("classical"):
                return [.brown, .orange]
            case let name where name.contains("hip") || name.contains("rap"):
                return [.yellow, .orange]
            case let name where name.contains("pop"):
                return [.pink, .purple]
            case let name where name.contains("country"):
                return [.orange, .brown]
            case let name where name.contains("metal"):
                return [.gray, .black]
            case let name where name.contains("r&b") || name.contains("soul"):
                return [.purple, .pink]
            default:
                return [.accentColor, .accentColor.opacity(0.7)]
            }
        }()
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var genreIcon: String {
        switch genre.name.lowercased() {
        case let name where name.contains("rock"):
            return "guitars"
        case let name where name.contains("jazz"):
            return "music.quarternote.3"
        case let name where name.contains("electronic") || name.contains("edm"):
            return "waveform"
        case let name where name.contains("classical"):
            return "music.note.list"
        case let name where name.contains("hip") || name.contains("rap"):
            return "music.mic"
        case let name where name.contains("pop"):
            return "sparkles"
        case let name where name.contains("country"):
            return "music.note"
        case let name where name.contains("metal"):
            return "bolt.fill"
        default:
            return "music.note"
        }
    }
}

#Preview {
    NavigationStack {
        GenreDetailView(genre: Genre(name: "Rock", songCount: 150, albumCount: 25))
            .environment(AppState())
    }
}
