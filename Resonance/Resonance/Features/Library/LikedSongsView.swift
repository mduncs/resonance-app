import SwiftUI

struct LikedSongsView: View {
    @Environment(AppState.self) private var appState
    @State private var likedSongs: [LikedSongRow] = []
    @State private var searchText = ""
    @State private var viewState: ViewState = .loading
    @State private var selectedSongIds = Set<String>()
    @State private var sortOption: SortOption = .recentlyLiked
    @State private var errorMessage = "Failed to load liked songs."
    @State private var allLikedSongsHidden = false

    enum ViewState {
        case loading, empty, populated, error
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case recentlyLiked
        case oldestLiked
        case title
        case artist
        case album

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recentlyLiked: return "Recently Liked"
            case .oldestLiked: return "Oldest Liked"
            case .title: return "Title"
            case .artist: return "Artist"
            case .album: return "Album"
            }
        }
    }

    private var songs: [Song] {
        likedSongs.map(\.song)
    }

    private var filteredRows: [LikedSongRow] {
        if searchText.isEmpty { return likedSongs }
        let query = searchText.lowercased()
        return likedSongs.filter {
            $0.song.title.lowercased().contains(query) ||
            $0.song.artist.lowercased().contains(query) ||
            $0.song.album.lowercased().contains(query)
        }
    }

    private var sortedRows: [LikedSongRow] {
        filteredRows.sorted(by: sortComparator)
    }

    private var sortedSongs: [Song] {
        sortedRows.map(\.song)
    }

    private var totalDuration: String {
        let total = sortedSongs.reduce(0) { $0 + $1.duration }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let songCountLabel: String
        if searchText.isEmpty {
            songCountLabel = "\(sortedSongs.count) songs"
        } else {
            songCountLabel = "\(sortedSongs.count) of \(songs.count) songs"
        }
        if hours > 0 {
            return "\(songCountLabel), \(hours) hr \(minutes) min"
        }
        return "\(songCountLabel), \(minutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Liked Songs")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        if !songs.isEmpty {
                            Text(totalDuration)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !songs.isEmpty {
                        Button {
                            Task { await playSongs(shuffled: true) }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(sortedSongs.isEmpty)

                        Button {
                            Task { await playSongs() }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(sortedSongs.isEmpty)
                    }
                }

                if !songs.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("Search liked songs", text: $searchText)
                            .textFieldStyle(.plain)
                        Spacer(minLength: 12)
                        Picker("Sort", selection: $sortOption) {
                            ForEach(SortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()

            // Content
            switch viewState {
            case .loading:
                InlineLoadingStatusView(title: "Loading liked songs...")
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

            case .error:
                CompactStatusView(
                    title: "Couldn't Load",
                    systemImage: "exclamationmark.triangle",
                    message: errorMessage,
                    actionTitle: "Retry",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await loadSongs(showLoading: true) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            case .empty:
                CompactStatusView(
                    title: "No Liked Songs",
                    systemImage: "plus.circle",
                    message: allLikedSongsHidden
                        ? "All liked songs for this server are currently hidden."
                        : "Songs you like appear here. Resonance keeps them locally for offline playback and mirrors Navidrome stars when available."
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            case .populated:
                if sortedRows.isEmpty && !searchText.isEmpty {
                    CompactStatusView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        message: "No liked songs match \"\(searchText)\"."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    songList
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadSongs(showLoading: true)
        }
        .onChange(of: appState.activeServerId) { _, _ in
            Task { await loadSongs(showLoading: true) }
        }
        .onChange(of: appState.likedSongIds) { _, _ in
            Task { await loadSongs() }
        }
        .onChange(of: appState.hiddenSongIds) { _, _ in
            Task { await loadSongs() }
        }
    }

    @ViewBuilder
    private var songList: some View {
        Table(sortedRows, selection: $selectedSongIds) {
            TableColumn("") { row in
                let song = row.song

                if appState.nowPlaying?.id == song.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                } else if song.starred != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .font(.caption)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .width(30)

            TableColumn("Title") { row in
                let song = row.song

                HStack(spacing: 12) {
                    EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                        .frame(width: 36, height: 36)
                        .cornerRadius(4)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .fontWeight(appState.nowPlaying?.id == song.id ? .semibold : .regular)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            TableColumn("Album") { row in
                Text(row.song.album)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Liked") { row in
                Text(relativeDate(row.likedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .width(90)

            TableColumn("Duration") { row in
                Text(row.song.formattedDuration)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(55)
        }
        .tableStyle(.inset)
        .frame(minHeight: 240, maxHeight: .infinity)
        .contextMenu(forSelectionType: String.self) { selectedIds in
            if let songId = selectedIds.first,
               let song = sortedRows.first(where: { $0.id == songId })?.song {
                SongContextMenu(song: song)
            }
        } primaryAction: { selectedIds in
            if let songId = selectedIds.first,
               let index = sortedRows.firstIndex(where: { $0.id == songId }) {
                Task {
                    await appState.playbackManager.play(songs: sortedSongs, startingAt: index)
                }
            }
        }
    }

    // MARK: - Data

    private func loadSongs(showLoading: Bool = false) async {
        guard let serverId = appState.activeServerId else {
            likedSongs = []
            allLikedSongsHidden = false
            errorMessage = "Select a server to view liked songs."
            viewState = .error
            return
        }

        if showLoading {
            viewState = .loading
        }

        do {
            let loadedSongs = try appState.databaseManager.loadLikedSongRows(serverId: serverId)
            let visibleSongIds = Set(appState.visibleSongsForPlayback(
                loadedSongs.map(\.song),
                serverId: serverId
            ).map(\.id))
            let visibleSongs = loadedSongs.filter { visibleSongIds.contains($0.song.id) }

            likedSongs = visibleSongs
            allLikedSongsHidden = !loadedSongs.isEmpty && visibleSongs.isEmpty
            viewState = visibleSongs.isEmpty ? .empty : .populated
        } catch {
            likedSongs = []
            allLikedSongsHidden = false
            errorMessage = error.localizedDescription
            viewState = .error
        }
    }

    private func playSongs(shuffled: Bool = false) async {
        var toPlay = sortedSongs
        if shuffled { toPlay.shuffle() }
        if !toPlay.isEmpty {
            await appState.playbackManager.play(songs: toPlay)
        }
    }

    // MARK: - Helpers

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func relativeDate(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func sortComparator(lhs: LikedSongRow, rhs: LikedSongRow) -> Bool {
        switch sortOption {
        case .recentlyLiked:
            return lhs.likedAt > rhs.likedAt
        case .oldestLiked:
            return lhs.likedAt < rhs.likedAt
        case .title:
            return compare(lhs.song.title, rhs.song.title, fallback: lhs.likedAt > rhs.likedAt)
        case .artist:
            let artistComparison = lhs.song.artist.localizedCaseInsensitiveCompare(rhs.song.artist)
            if artistComparison != .orderedSame {
                return artistComparison == .orderedAscending
            }
            return compare(lhs.song.title, rhs.song.title, fallback: lhs.likedAt > rhs.likedAt)
        case .album:
            let albumComparison = lhs.song.album.localizedCaseInsensitiveCompare(rhs.song.album)
            if albumComparison != .orderedSame {
                return albumComparison == .orderedAscending
            }
            return compare(lhs.song.title, rhs.song.title, fallback: lhs.likedAt > rhs.likedAt)
        }
    }

    private func compare(_ lhs: String, _ rhs: String, fallback: @autoclosure () -> Bool) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame {
            return fallback()
        }
        return comparison == .orderedAscending
    }
}

#Preview {
    NavigationStack {
        LikedSongsView()
            .environment(AppState())
    }
}
