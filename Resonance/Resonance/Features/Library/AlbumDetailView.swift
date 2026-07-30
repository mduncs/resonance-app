import SwiftUI

// MARK: - Sequence Extension

private extension Sequence where Element: Hashable {
    /// Returns an array with duplicate elements removed, preserving order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Album Detail View

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    let album: Album

    @State private var songs: [Song] = []
    @State private var viewState: ViewState = .loading
    @State private var moreByArtist: [Album] = []
    @State private var isLoadingMore = false
    @State private var selectedArtist: Artist?
    @State private var selectedGenre: String?
    @State private var isStarred: Bool
    @State private var cachedSongsByDisc: [(disc: Int, songs: [Song])] = []
    @State private var searchText: String = ""
    /// Captured on init to persist highlight even after AppState clears it
    @State private var highlightSongId: String?

    enum ViewState: Equatable {
        case loading
        case error(ResonanceError)
        case populated

        static func == (lhs: ViewState, rhs: ViewState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.populated, .populated):
                return true
            case (.error, .error):
                return true  // Compare by case only, not error details
            default:
                return false
            }
        }
    }

    init(album: Album) {
        self.album = album
        self._isStarred = State(initialValue: album.starred != nil)
    }

    /// Current song ID from playback for highlighting
    private var currentSongId: String? {
        appState.queueManager.currentItem?.song.id
    }

    /// Songs grouped by disc number (cached to avoid recomputing on every render)
    private var songsByDisc: [(disc: Int, songs: [Song])] {
        cachedSongsByDisc
    }

    private func updateSongsByDisc() {
        let grouped = Dictionary(grouping: songs) { $0.discNumber ?? 1 }
        cachedSongsByDisc = grouped.keys.sorted().map { (disc: $0, songs: grouped[$0]!) }
    }

    /// Whether to show disc separators (only if multiple discs)
    private var hasMultipleDiscs: Bool {
        songsByDisc.count > 1
    }

    private var isAlbumAdmitted: Bool {
        appState.admittedAlbumIds.contains(album.id)
    }

    /// Songs filtered by search text
    private var filteredSongs: [Song] {
        guard !searchText.isEmpty else { return songs }
        let query = searchText.lowercased()
        return songs.filter {
            $0.title.lowercased().contains(query) ||
            $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    AlbumHeaderView(
                    album: album,
                    songs: songs,
                    isStarred: isStarred,
                    onPlay: {
                        Task {
                            await appState.playbackManager.play(songs: songs)
                        }
                    },
                    onShuffle: {
                        Task {
                            await appState.playbackManager.play(songs: songs.shuffled())
                        }
                    },
                    onToggleStar: {
                        Task {
                            await toggleAlbumStar()
                        }
                    },
                    onArtistTap: {
                        navigateToArtist()
                    },
                    onGenreTap: { genre in
                        selectedGenre = genre
                    }
                )

                if !isAlbumAdmitted {
                    ReleaseShadowBanner(
                        title: "Release Shadow",
                        detail: "\(album.name) is outside Library",
                        actionTitle: "Admit"
                    ) {
                        Task {
                            await admitAlbum()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }

                Divider()
                    .padding(.horizontal)

                // Track list
                switch viewState {
                case .loading:
                    let placeholderCount = max(3, min(album.songCount, 15))
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        SongRow(song: .placeholder)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal)

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
                    .padding(.horizontal)

                case .populated:
                    trackListView
                        .padding(.horizontal)

                    // Credits section (if we have songwriter/composer info from songs)
                    creditsSection

                    // More by Artist section
                    moreByArtistSection
                }
            }
        }
        .onChange(of: viewState) { _, newState in
            // Scroll to highlighted song after songs load
            if case .populated = newState, let songId = highlightSongId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(songId, anchor: .center)
                    }
                }
            }
        }
        }
        .navigationTitle(album.name)
        .searchable(text: $searchText, prompt: "Find in Album")
        .toolbar {
            // .primaryAction keeps these trailing; without an explicit placement
            // .automatic drops them next to the back chevron, where they read as
            // a second transport cluster competing with the floating bar.
            // Play/Shuffle live in AlbumHeaderView, so they are not repeated here.
            ToolbarItemGroup(placement: .primaryAction) {
                if !isAlbumAdmitted {
                    Button {
                        Task {
                            await admitAlbum()
                        }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Admit Album")
                }

                Menu {
                    Button {
                        // Add to queue
                        songs.forEach { appState.playbackManager.addToQueue($0) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Button {
                        // Play next
                        songs.reversed().forEach { appState.playbackManager.playNext($0) }
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Divider()

                    Button {
                        Task {
                            await toggleAlbumStar()
                        }
                    } label: {
                        Label(isStarred ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: isStarred ? "heart.fill" : "heart")
                    }

                    // Rating picker
                    RatingPicker(currentRating: album.rating) { newRating in
                        setRating(newRating)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadSongs()
        }
        .task {
            await loadMoreByArtist()
        }
        .onAppear {
            // Capture the highlight song ID from AppState (set by NowPlayingBar navigation)
            if let songId = appState.navigationTargetSongId {
                highlightSongId = songId
                appState.navigationTargetSongId = nil  // Clear after capturing
            }
        }
        .onChange(of: selectedGenre) { _, genre in
            if let genre {
                appState.detailNavigationPath.append(
                    Genre(
                        name: genre,
                        songCount: songs.filter { $0.genre == genre }.count,
                        albumCount: albumsMatchingGenre(genre).count
                    )
                )
                selectedGenre = nil
            }
        }
    }

    // MARK: - Track List View

    @ViewBuilder
    private var trackListView: some View {
        let songsToDisplay = filteredSongs
        let isSearching = !searchText.isEmpty

        LazyVStack(spacing: 0) {
            if songs.isEmpty {
                CompactStatusView(
                    title: "No Songs",
                    systemImage: "music.note",
                    message: "No tracks found for this album."
                )
                .padding(.vertical, 40)
            } else if isSearching {
                // Flat list when searching
                if songsToDisplay.isEmpty {
                    CompactStatusView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        message: "No tracks match \"\(searchText)\"."
                    )
                        .padding(.vertical, 40)
                } else {
                    ForEach(Array(songsToDisplay.enumerated()), id: \.element.id) { index, song in
                        trackRow(song: song, index: songs.firstIndex(of: song) ?? index)
                            .id(song.id)

                        if index < songsToDisplay.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            } else if hasMultipleDiscs {
                ForEach(songsByDisc, id: \.disc) { discGroup in
                    // Disc header
                    HStack {
                        Text("Disc \(discGroup.disc)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, discGroup.disc == 1 ? 8 : 24)
                    .padding(.bottom, 8)

                    // Songs in this disc
                    ForEach(Array(discGroup.songs.enumerated()), id: \.element.id) { index, song in
                        trackRow(song: song, index: songs.firstIndex(of: song) ?? index)
                            .id(song.id)

                        if index < discGroup.songs.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    trackRow(song: song, index: index)
                        .id(song.id)

                    if index < songs.count - 1 {
                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trackRow(song: Song, index: Int) -> some View {
        let isPlaying = song.id == currentSongId
        let isHighlighted = song.id == highlightSongId

        AlbumTrackRow(
            song: song,
            albumArtist: album.artist,
            isPlaying: isPlaying,
            isHighlighted: isHighlighted,
            onDoubleTap: {
                Task {
                    await appState.playbackManager.play(songs: songs, startingAt: index)
                }
            }
        )
        .contextMenu {
            SongContextMenu(song: song)
        }
    }

    // MARK: - Credits Section

    @ViewBuilder
    private var creditsSection: some View {
        let genres = songs.compactMap(\.genre).uniqued()

        if !genres.isEmpty || album.year != nil {
            VStack(alignment: .leading, spacing: 16) {
                Text("About")
                    .font(.title3)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 12) {
                    // Release info
                    if let year = album.year {
                        HStack {
                            Text("Released")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(year))
                        }
                        .font(.subheadline)
                    }

                    // Genre
                    if let genre = album.genre ?? genres.first {
                        HStack {
                            Text("Genre")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(genre) {
                                selectedGenre = genre
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                        .font(.subheadline)
                    }

                    // Track count and duration
                    HStack {
                        Text("Tracks")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(album.songCount) songs, \(formattedTotalDuration)")
                    }
                    .font(.subheadline)
                }
                .padding()
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .padding()
        }
    }

    private var formattedTotalDuration: String {
        let totalSeconds = album.duration
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    private func albumsMatchingGenre(_ genre: String) -> Set<String> {
        Set(songs.filter { $0.genre == genre }.map(\.albumId))
    }

    // MARK: - More by Artist Section

    @ViewBuilder
    private var moreByArtistSection: some View {
        let otherAlbums = moreByArtist.filter { $0.id != album.id }

        if !otherAlbums.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("More by \(album.artist)")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Spacer()

                    Button {
                        navigateToArtist()
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(otherAlbums.prefix(10)) { otherAlbum in
                            NavigationLink(value: otherAlbum) {
                                AlbumCard(album: otherAlbum)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task {
                                        await playAlbum(otherAlbum)
                                    }
                                } label: {
                                    Label("Play", systemImage: "play")
                                }

                                Button {
                                    Task {
                                        await playAlbum(otherAlbum, shuffled: true)
                                    }
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                }

                                Button {
                                    Task {
                                        await addAlbumToQueue(otherAlbum)
                                    }
                                } label: {
                                    Label("Add to Queue", systemImage: "text.badge.plus")
                                }

                                Divider()

                                Button {
                                    appState.getInfoContent = .album(otherAlbum)
                                } label: {
                                    Label("Get Info", systemImage: "info.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        } else if isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    // MARK: - Actions

    private func loadSongs() async {
        viewState = .loading

        do {
            let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
            let admittedSongIds = appState.activeServerId.flatMap {
                try? appState.databaseManager.loadLibraryMemberIds(type: .song, serverId: $0)
            } ?? appState.admittedSongIds
            let filteredSongs = fetchedSongs.filter {
                !appState.hiddenSongIds.contains($0.id) &&
                (!isAlbumAdmitted || admittedSongIds.contains($0.id))
            }
            await MainActor.run {
                songs = filteredSongs
                updateSongsByDisc()
                viewState = .populated
            }
        } catch let error as ResonanceError {
            viewState = .error(error)
        } catch {
            viewState = .error(.networkUnavailable)
        }
    }

    private func loadMoreByArtist() async {
        guard !album.artistId.isEmpty else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let artistDetail = try await appState.networkActor.fetchArtist(id: album.artistId)
            let admittedAlbumIds = appState.activeServerId.flatMap {
                try? appState.databaseManager.loadLibraryMemberIds(type: .album, serverId: $0)
            } ?? appState.admittedAlbumIds
            moreByArtist = artistDetail.albums.filter {
                !appState.hiddenAlbumIds.contains($0.id) &&
                (!isAlbumAdmitted || admittedAlbumIds.contains($0.id))
            }
        } catch {
            // Non-critical - just don't show the section
        }
    }

    private func admitAlbum() async {
        guard let serverId = appState.activeServerId else { return }

        do {
            let songsToAdmit: [Song]
            if songs.isEmpty {
                let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                songsToAdmit = fetchedSongs
                songs = fetchedSongs.filter { !appState.hiddenSongIds.contains($0.id) }
                updateSongsByDisc()
            } else {
                songsToAdmit = songs
            }

            try appState.databaseManager.saveAlbums([album], serverId: serverId)
            try appState.databaseManager.saveSongs(songsToAdmit, serverId: serverId)
            try appState.databaseManager.admitToLibrary(
                id: album.id,
                type: .album,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "album_detail"
            )
            if !album.artistId.isEmpty {
                try appState.databaseManager.admitToLibrary(
                    id: album.artistId,
                    type: .artist,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "album_detail"
                )
            }
            for song in songsToAdmit {
                try appState.databaseManager.admitSongAndRelated(
                    song,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "album_detail"
                )
                try appState.databaseManager.upsertWaitingRoomItem(
                    song: song,
                    serverId: serverId,
                    state: .admitted,
                    source: "album_detail_admit"
                )
                try appState.databaseManager.setWaitingRoomState(
                    songId: song.id,
                    serverId: serverId,
                    state: .admitted
                )
            }
            appState.refreshLibraryMembershipIds()
            viewState = .populated
        } catch {
            print("Failed to admit album: \(error)")
        }
    }

    private func playAlbum(_ candidate: Album, shuffled: Bool = false) async {
        do {
            var albumSongs = try await loadPlayableAlbumSongs(candidate)
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

    private func addAlbumToQueue(_ candidate: Album) async {
        do {
            let albumSongs = try await loadPlayableAlbumSongs(candidate)
            for song in albumSongs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add album to queue: \(error)")
        }
    }

    private func loadPlayableAlbumSongs(_ candidate: Album) async throws -> [Song] {
        let candidateIsAdmitted = loadIsInLibrary(
            id: candidate.id,
            type: .album,
            fallback: appState.admittedAlbumIds.contains(candidate.id)
        )
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: candidate.id)
        return fetchedSongs.filter {
            !hiddenSongIds.contains($0.id) &&
            (!candidateIsAdmitted || admittedSongIds.contains($0.id))
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

    private func loadIsInLibrary(id: String, type: LibraryItemType, fallback: Bool) -> Bool {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.isInLibrary(id: id, type: type, serverId: serverId)) ?? fallback
    }

    private func toggleAlbumStar() async {
        do {
            if isStarred {
                try await appState.networkActor.unstar(id: album.id, type: .album)
                appState.updateAlbumStarred(id: album.id, starred: nil)
                isStarred = false
            } else {
                try await appState.networkActor.star(id: album.id, type: .album)
                appState.updateAlbumStarred(id: album.id, starred: Date())
                isStarred = true
            }
        } catch {
            // API call failed, don't update local state
        }
    }

    private func setRating(_ rating: Int) {
        let newRating = rating == 0 ? nil : rating

        // Optimistic update
        appState.updateAlbumRating(id: album.id, rating: newRating)

        Task {
            do {
                try await appState.networkActor.setRating(id: album.id, rating: rating)
            } catch {
                // Revert on failure - but we don't have previous state easily accessible
            }
        }
    }

    private func navigateToArtist() {
        appState.navigationTargetArtistId = album.artistId
        appState.selectedSidebarItem = .artists
    }
}

// MARK: - Album Track Row

/// Specialized track row for album detail view
struct AlbumTrackRow: View {
    let song: Song
    let albumArtist: String
    var isPlaying: Bool = false
    var isHighlighted: Bool = false
    var onDoubleTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Track number or playing indicator
            Group {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    Text("\(song.track ?? 0)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.body)
                        .fontWeight(isPlaying || isHighlighted ? .semibold : .regular)
                        .foregroundStyle(isPlaying || isHighlighted ? Color.accentColor : .primary)
                        .lineLimit(1)

                    // Starred indicator
                    if song.starred != nil {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }

                    // Explicit indicator
                    if song.isExplicit {
                        Text("E")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .cornerRadius(2)
                    }
                }

                // Show featuring artist if different from album artist
                if song.artist != albumArtist {
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Indicators
            HStack(spacing: 8) {
                // Rating indicator
                RatingIndicator(rating: song.rating)

                // Duration
                Text(song.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, isHighlighted ? 8 : 0)
        .background(
            isHighlighted
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to play")
        .accessibilityAddTraits(isPlaying ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var label = "Track \(song.track ?? 0): \(song.title)"
        if isPlaying {
            label = "Now playing: " + label
        }
        label += ", \(song.formattedDuration)"
        if song.starred != nil {
            label += ", loved"
        }
        if song.isExplicit {
            label += ", explicit"
        }
        return label
    }
}

struct AlbumHeaderView: View {
    let album: Album
    let songs: [Song]
    let isStarred: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onToggleStar: () -> Void
    var onArtistTap: (() -> Void)? = nil
    var onGenreTap: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            // Album art with shadow
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            }

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text("Album")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(album.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .lineLimit(2)

                // Clickable artist name (accent color for better affordance)
                Button {
                    onArtistTap?()
                } label: {
                    Text(album.artist)
                        .font(.title2)
                        .foregroundStyle(onArtistTap != nil ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(onArtistTap == nil)

                // Metadata row
                HStack(spacing: 8) {
                    if let year = album.year {
                        Text(String(year))
                    }

                    if let genre = album.genre {
                        Text("•")
                        if let onGenreTap {
                            Button(genre) {
                                onGenreTap(genre)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(genre)
                        }
                    }

                    Text("•")
                    Text("\(album.songCount) songs")

                    Text("•")
                    Text(formattedDuration)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer()

                // Action buttons (both outlined style, like Apple Music)
                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .disabled(songs.isEmpty)

                    Button(action: onShuffle) {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(songs.isEmpty)

                    Spacer()

                    // Love/Star button
                    Button(action: onToggleStar) {
                        Image(systemName: isStarred ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isStarred ? .pink : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isStarred ? "Remove from Favorites" : "Add to Favorites")
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private var formattedDuration: String {
        let totalSeconds = album.duration
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView(album: .placeholder)
            .environment(AppState())
    }
}
