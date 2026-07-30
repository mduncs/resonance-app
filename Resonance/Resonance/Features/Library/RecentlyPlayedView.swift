import SwiftUI

struct RecentlyPlayedView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var recentItems: [RecentlyPlayedItem] = []
    @State private var selection = Set<String>()
    @State private var groupByDate = true

    enum ViewState {
        case loading
        case empty
        case populated
    }

    private var groupedItems: [(String, [RecentlyPlayedItem])] {
        guard groupByDate else {
            return [("All", recentItems)]
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recentItems) { item -> String in
            if calendar.isDateInToday(item.playedAt) {
                return "Today"
            } else if calendar.isDateInYesterday(item.playedAt) {
                return "Yesterday"
            } else if let daysAgo = calendar.dateComponents([.day], from: item.playedAt, to: Date()).day,
                      daysAgo < 7 {
                return "This Week"
            } else if let daysAgo = calendar.dateComponents([.day], from: item.playedAt, to: Date()).day,
                      daysAgo < 30 {
                return "This Month"
            } else {
                return "Earlier"
            }
        }

        let order = ["Today", "Yesterday", "This Week", "This Month", "Earlier"]
        return order.compactMap { key in
            guard let items = grouped[key] else { return nil }
            return (key, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                Text("Recently Played")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Toggle(isOn: $groupByDate) {
                    Image(systemName: groupByDate ? "calendar" : "list.bullet")
                }
                .toggleStyle(.button)
                .help(groupByDate ? "Show as list" : "Group by date")

                Menu {
                    Button {
                        Task { await playAllRecent() }
                    } label: {
                        Label("Play All", systemImage: "play")
                    }
                    .disabled(recentItems.isEmpty)

                    Button {
                        Task { await playAllRecent(shuffled: true) }
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(recentItems.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        Task { await clearHistory() }
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(recentItems.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Content
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading recently played...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Recently Played",
                        systemImage: "clock",
                        message: "Start playing music to see your history here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    List(selection: $selection) {
                        ForEach(groupedItems, id: \.0) { section, items in
                            Section(section) {
                                ForEach(items) { item in
                                    RecentlyPlayedRow(item: item)
                                        .tag(item.id)
                                        .contextMenu {
                                            SongContextMenu(song: item.song)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .contextMenu(forSelectionType: String.self) { selectedIds in
                        if let itemId = selectedIds.first,
                           let item = recentItems.first(where: { $0.id == itemId }) {
                            SongContextMenu(song: item.song)
                        }
                    } primaryAction: { selectedIds in
                        if let itemId = selectedIds.first,
                           let item = recentItems.first(where: { $0.id == itemId }) {
                            Task {
                                await playItem(item)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadRecentlyPlayed()
        }
    }

    private func loadRecentlyPlayed() async {
        guard let serverId = appState.activeServerId else {
            recentItems = []
            viewState = .empty
            return
        }

        let history = (try? appState.databaseManager.loadPlayHistory(serverId: serverId, limit: 100)) ?? []
        let hiddenSongIds = (try? appState.databaseManager.loadHiddenIds(type: "song", serverId: serverId)) ?? appState.hiddenSongIds
        let hiddenAlbumIds = (try? appState.databaseManager.loadHiddenIds(type: "album", serverId: serverId)) ?? appState.hiddenAlbumIds
        let visibleHistory = history.filter {
            !hiddenSongIds.contains($0.songId) &&
            !hiddenAlbumIds.contains($0.albumId)
        }

        // Count plays per song for playCount display
        var playCounts: [String: Int] = [:]
        for item in visibleHistory {
            playCounts[item.songId, default: 0] += 1
        }

        recentItems = visibleHistory.map { entry in
            let song = Song(
                id: entry.songId,
                title: entry.title,
                album: entry.album,
                albumId: entry.albumId,
                artist: entry.artist,
                artistId: "",  // Not stored in history
                track: nil,
                discNumber: nil,
                year: nil,
                genre: nil,
                duration: entry.durationPlayed ?? 0,
                bitRate: nil,
                contentType: "audio/mpeg",
                suffix: "mp3",
                coverArt: entry.coverArt
            )
            return RecentlyPlayedItem(
                song: song,
                playedAt: entry.playedAt,
                playCount: playCounts[entry.songId] ?? 1
            )
        }

        viewState = recentItems.isEmpty ? .empty : .populated
    }

    private func clearHistory() async {
        try? appState.databaseManager.write { db in
            try db.execute(sql: "DELETE FROM play_history")
        }
        recentItems = []
        viewState = .empty
    }

    private func playItem(_ item: RecentlyPlayedItem) async {
        let songs = recentItems.map(\.song)
        if let index = recentItems.firstIndex(where: { $0.id == item.id }) {
            await appState.playbackManager.play(songs: songs, startingAt: index)
        }
    }

    private func playAllRecent(shuffled: Bool = false) async {
        var songs = recentItems.map(\.song)
        if shuffled {
            songs.shuffle()
        }
        await appState.playbackManager.play(songs: songs)
    }
}

// MARK: - Recently Played Item

struct RecentlyPlayedItem: Identifiable, Sendable {
    var id: String { "\(song.id)_\(playedAt.timeIntervalSince1970)" }
    let song: Song
    let playedAt: Date
    let playCount: Int

    var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: playedAt, relativeTo: Date())
    }
}

// MARK: - Recently Played Row

struct RecentlyPlayedRow: View {
    @Environment(AppState.self) private var appState
    let item: RecentlyPlayedItem

    private var isPlaying: Bool {
        appState.nowPlaying?.id == item.song.id && appState.playbackState == .playing
    }

    var body: some View {
        HStack(spacing: 12) {
            // Playing indicator or album art
            ZStack {
                EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                    .frame(width: 44, height: 44)

                if isPlaying {
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(.body)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(item.song.artist)
                    Text("•")
                    Text(item.song.album)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.playCount > 1 {
                    Text("\(item.playCount) plays")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(item.song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        RecentlyPlayedView()
            .environment(AppState())
    }
}
