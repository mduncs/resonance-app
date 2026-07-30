import SwiftUI

struct SongsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var songs: [Song] = []
    @State private var displayedSongs: [Song] = []
    @State private var sortOrder: SongSortOrder = .title
    @State private var selection = Set<String>()
    @State private var totalCount: Int = 0
    @State private var syncProgress: Int = 0
    @State private var isSyncing = false

    enum ViewState: Equatable {
        case loading
        case empty
        case error(ResonanceError)
        case populated

        static func == (lhs: ViewState, rhs: ViewState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.empty, .empty), (.populated, .populated): return true
            case (.error, .error): return true
            default: return false
            }
        }
    }

    enum SongSortOrder: String, CaseIterable {
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        case duration = "Duration"
    }

    private func sortSongs(_ input: [Song]) -> [Song] {
        let hiddenSongIds = appState.hiddenSongIds
        let hiddenAlbumIds = appState.hiddenAlbumIds
        let filtered = input.filter { !hiddenSongIds.contains($0.id) && !hiddenAlbumIds.contains($0.albumId) }

        switch sortOrder {
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return filtered.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:
            return filtered.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .duration:
            return filtered.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Songs")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    HStack(spacing: 6) {
                        if totalCount > 0 {
                            Text("\(totalCount) songs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if isSyncing {
                            Text("syncing \(syncProgress)...")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(displayedSongs.isEmpty)
                    .help("Play All")

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .disabled(displayedSongs.isEmpty)
                    .help("Shuffle All")

                    Menu {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(SongSortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sort Order")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading songs...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Songs",
                        systemImage: "music.note.list",
                        message: "Songs from your library will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadSongs() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if displayedSongs.isEmpty {
                        CompactStatusView(
                            title: "No Songs",
                            systemImage: "music.note.list",
                            message: "No songs match the current filters."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        SongTableView(
                            songs: displayedSongs,
                            allSongs: songs,
                            selection: $selection,
                            nowPlayingId: appState.nowPlaying?.id,
                            cacheActor: appState.cacheActor,
                            networkActor: appState.networkActor,
                            onPlay: { song in
                                Task {
                                    if let index = displayedSongs.firstIndex(of: song) {
                                        await appState.playbackManager.play(songs: displayedSongs, startingAt: index)
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadSongs()
        }
        .onChange(of: sortOrder) { _, _ in
            displayedSongs = sortSongs(songs)
        }
    }

    private func loadSongs() async {
        // Use GRDB cache — LibraryRefreshScheduler handles background sync
        guard let serverId = appState.activeServerId else {
            viewState = .loading
            return
        }

        if let cached = try? appState.databaseManager.loadAdmittedSongs(serverId: serverId),
           !cached.isEmpty {
            songs = cached
            totalCount = cached.count
            displayedSongs = sortSongs(cached)
            viewState = .populated
            return
        }

        // Cache empty — need initial fetch
        await syncSongs(serverId: serverId)
    }

    /// Full network sync — only on first launch when cache is empty
    private func syncSongs(serverId: String) async {
        viewState = .loading
        isSyncing = true
        syncProgress = 0

        var allSongs: [Song] = []
        var seenIds = Set<String>()
        let pageSize = 500
        var offset = 0

        do {
            while true {
                let batch = try await appState.networkActor.fetchSongPage(offset: offset, pageSize: pageSize)
                let newSongs = batch.filter { seenIds.insert($0.id).inserted }
                allSongs.append(contentsOf: newSongs)
                syncProgress = allSongs.count

                if batch.count < pageSize || newSongs.isEmpty { break }
                offset += batch.count
            }

            try? appState.databaseManager.saveSongs(allSongs, serverId: serverId)
            appState.refreshLibraryMembershipIds()
            let admitted = (try? appState.databaseManager.loadAdmittedSongs(serverId: serverId)) ?? allSongs

            songs = admitted
            totalCount = admitted.count
            displayedSongs = sortSongs(admitted)
            viewState = displayedSongs.isEmpty ? .empty : .populated
        } catch {
            if songs.isEmpty {
                viewState = .error(error as? ResonanceError ?? .networkUnavailable)
            }
        }

        isSyncing = false
        syncProgress = 0
    }

    private func playAll(shuffled: Bool = false) async {
        var songsToPlay = displayedSongs
        if shuffled {
            songsToPlay.shuffle()
        }
        await appState.playbackManager.play(songs: songsToPlay)
    }
}

struct SongTableView: View {
    let songs: [Song]
    let allSongs: [Song]
    @Binding var selection: Set<String>
    let nowPlayingId: String?
    let cacheActor: CacheActor
    let networkActor: NetworkActor
    let onPlay: (Song) -> Void

    @FocusState private var isTableFocused: Bool

    var body: some View {
        Table(songs, selection: $selection) {
            TableColumn("") { song in
                if selection.contains(song.id) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(isTableFocused ? 0 : 1)
                }
            }
            .width(16)

            TableColumn("") { song in
                if nowPlayingId == song.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                }
            }
            .width(24)

            TableColumn("\u{2665}") { song in
                if song.starred != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .width(30)

            TableColumn("Title") { song in
                HStack(spacing: 12) {
                    AlbumArtView(
                        coverArtId: song.coverArt,
                        size: .small,
                        cacheActor: cacheActor,
                        networkActor: networkActor
                    )
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                    .drawingGroup()

                    Text(song.title)
                        .fontWeight(nowPlayingId == song.id ? .semibold : .regular)
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
        .frame(minHeight: 240, maxHeight: .infinity)
        .focusable()
        .focused($isTableFocused)
        .focusEffectDisabled()
        .contextMenu(forSelectionType: String.self) { selectedIds in
            let selectedSongs = allSongs.filter { selectedIds.contains($0.id) }
            if selectedSongs.count > 1 {
                BulkSongContextMenu(songs: selectedSongs)
            } else if let song = selectedSongs.first {
                SongContextMenu(song: song)
            }
        } primaryAction: { selectedIds in
            if let songId = selectedIds.first,
               let song = songs.first(where: { $0.id == songId }) {
                onPlay(song)
            }
        }
        .onKeyPress(.return) {
            if let songId = selection.first,
               let song = songs.first(where: { $0.id == songId }) {
                onPlay(song)
                return .handled
            }
            return .ignored
        }
        .onAppear {
            isTableFocused = true
        }
    }
}

#Preview {
    SongsView()
        .environment(AppState())
}
