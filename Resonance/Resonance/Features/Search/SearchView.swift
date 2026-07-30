import SwiftUI

// MARK: - Recent Searches Manager

@MainActor
@Observable
final class RecentSearchesManager {
    private let maxItems = 10
    private let userDefaultsKey = "recentSearches"

    var recentSearches: [String] = []

    init() {
        loadFromDefaults()
    }

    func addSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove if exists (will re-add at front)
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }

        // Insert at front
        recentSearches.insert(trimmed, at: 0)

        // Trim to max
        if recentSearches.count > maxItems {
            recentSearches = Array(recentSearches.prefix(maxItems))
        }

        saveToDefaults()
    }

    func removeSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        saveToDefaults()
    }

    func clearAll() {
        recentSearches.removeAll()
        saveToDefaults()
    }

    private func loadFromDefaults() {
        recentSearches = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
    }

    private func saveToDefaults() {
        UserDefaults.standard.set(recentSearches, forKey: userDefaultsKey)
    }
}

// MARK: - Search View

private enum SearchScope: String, CaseIterable {
    case library = "Library"
    case global = "Global"
}

private struct SearchResultCounts {
    var artists = 0
    var albums = 0
    var songs = 0

    var total: Int {
        artists + albums + songs
    }
}

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var results: SearchResults?
    @State private var unfilteredResultCounts = SearchResultCounts()
    @State private var isSearching = false
    @State private var searchError: ResonanceError?
    @State private var searchTask: Task<Void, Never>?
    @State private var recentSearchesManager = RecentSearchesManager()
    @State private var searchScope: SearchScope = .library

    // Expanded section states
    @State private var showAllArtists = false
    @State private var showAllAlbums = false
    @State private var showAllSongs = false

    /// Synced with appState.searchQuery for toolbar integration
    private var query: Binding<String> {
        Binding(
            get: { appState.searchQuery },
            set: { appState.searchQuery = $0 }
        )
    }

    private let displayLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            searchField

            // Content
            if isSearching {
                InlineLoadingStatusView(title: "Searching...")
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            } else if let error = searchError {
                searchErrorView(error)
            } else if let results {
                if results.isEmpty {
                    noResultsView
                } else {
                    searchResultsView(results)
                }
            } else {
                emptyStateView
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .onChange(of: appState.searchQuery) {
            // Reset expanded states when query changes
            showAllArtists = false
            showAllAlbums = false
            showAllSongs = false

            // Debounce search input
            searchTask?.cancel()

            // Clear results immediately if query is empty
            if appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = nil
                searchError = nil
                return
            }

            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch()
            }
        }
        .onChange(of: searchScope) {
            guard !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            searchTask?.cancel()
            Task {
                await performSearch()
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search artists, albums, songs...", text: query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        searchTask?.cancel()
                        Task {
                            await performSearch()
                            if !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                recentSearchesManager.addSearch(appState.searchQuery)
                            }
                        }
                    }

                if !query.wrappedValue.isEmpty {
                    Button {
                        query.wrappedValue = ""
                        results = nil
                        searchError = nil
                        searchTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(.quaternary)
            .cornerRadius(10)

            Picker("Scope", selection: $searchScope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Empty State (no query)

    private var emptyStateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Recent Searches
                if !recentSearchesManager.recentSearches.isEmpty {
                    recentSearchesSection
                }

                // Search Suggestions
                searchSuggestionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Searches")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Clear") {
                    withAnimation {
                        recentSearchesManager.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }

            FlowLayout(spacing: 8) {
                ForEach(recentSearchesManager.recentSearches, id: \.self) { search in
                    RecentSearchChip(
                        text: search,
                        onTap: {
                            query.wrappedValue = search
                        },
                        onRemove: {
                            withAnimation {
                                recentSearchesManager.removeSearch(search)
                            }
                        }
                    )
                }
            }
        }
    }

    private var searchSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try Searching For")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Label("An artist name", systemImage: "music.mic")
                Label("An album title", systemImage: "square.stack")
                Label("A song name", systemImage: "music.note")
                Label("A genre like Jazz or Rock", systemImage: "guitars")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - No Results

    private func searchErrorView(_ error: ResonanceError) -> some View {
        CompactStatusView(
            title: error.errorTitle,
            systemImage: error.systemImage,
            message: searchErrorMessage(error),
            actionTitle: "Retry",
            actionSystemImage: "arrow.clockwise",
            action: {
                Task { await performSearch() }
            }
        )
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noResultsView: some View {
        ScrollView {
            let hasGlobalMatches = searchScope == .library && unfilteredResultCounts.total > 0
            Group {
                if hasGlobalMatches {
                    CompactStatusView(
                        title: "No Library Results",
                        systemImage: "magnifyingglass",
                        message: "Global has matches for \"\(appState.searchQuery)\".",
                        actionTitle: "Search Global",
                        actionSystemImage: "globe",
                        action: {
                            searchScope = .global
                        }
                    )
                } else {
                    CompactStatusView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        message: "No matches for \"\(appState.searchQuery)\"."
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Search Results

    private func searchResultsView(_ results: SearchResults) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Top Results (first artist + first album if both exist)
                if !results.artists.isEmpty || !results.albums.isEmpty {
                    topResultsSection(results)
                }

                // Artists
                if !results.artists.isEmpty {
                    artistsSection(results.artists)
                }

                // Albums
                if !results.albums.isEmpty {
                    albumsSection(results.albums)
                }

                // Songs
                if !results.songs.isEmpty {
                    songsSection(results.songs)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Top Results Section

    private func topResultsSection(_ results: SearchResults) -> some View {
        SearchResultSection(title: "Top Results") {
            HStack(alignment: .top, spacing: 16) {
                // Top Artist
                if let artist = results.artists.first {
                    NavigationLink(value: artist) {
                        TopResultCard(
                            title: artist.name,
                            subtitle: "Artist",
                            icon: "music.mic",
                            coverArtId: artist.coverArt,
                            isCircular: true
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Top Album
                if let album = results.albums.first {
                    NavigationLink(value: album) {
                        TopResultCard(
                            title: album.name,
                            subtitle: album.artist,
                            icon: "square.stack",
                            coverArtId: album.coverArt,
                            isCircular: false
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
    }

    // MARK: - Artists Section

    private func artistsSection(_ artists: [Artist]) -> some View {
        let displayedArtists = showAllArtists ? artists : Array(artists.prefix(displayLimit))
        let hasMore = artists.count > displayLimit

        return SearchResultSection(
            title: "Artists",
            showSeeAll: hasMore && !showAllArtists,
            onSeeAll: { showAllArtists = true }
        ) {
            ForEach(displayedArtists) { artist in
                NavigationLink(value: artist) {
                    ArtistRow(artist: artist)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        Task {
                            await playArtist(artist)
                        }
                    } label: {
                        Label("Play", systemImage: "play")
                    }

                    Button {
                        Task {
                            await playArtist(artist, shuffled: true)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }

                    Button {
                        Task {
                            await addArtistToQueue(artist)
                        }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Divider()

                    Button {
                        appState.getInfoContent = .artist(artist)
                    } label: {
                        Label("Get Info", systemImage: "info.circle")
                    }
                }
            }
        }
    }

    // MARK: - Albums Section

    private func albumsSection(_ albums: [Album]) -> some View {
        let displayedAlbums = showAllAlbums ? albums : Array(albums.prefix(displayLimit))
        let hasMore = albums.count > displayLimit

        return SearchResultSection(
            title: "Albums",
            showSeeAll: hasMore && !showAllAlbums,
            onSeeAll: { showAllAlbums = true }
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 16) {
                ForEach(displayedAlbums) { album in
                    NavigationLink(value: album) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
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
                            appState.getInfoContent = .album(album)
                        } label: {
                            Label("Get Info", systemImage: "info.circle")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Songs Section

    private func songsSection(_ songs: [Song]) -> some View {
        let displayedSongs = showAllSongs ? songs : Array(songs.prefix(displayLimit))
        let hasMore = songs.count > displayLimit

        return SearchResultSection(
            title: "Songs",
            showSeeAll: hasMore && !showAllSongs,
            onSeeAll: { showAllSongs = true }
        ) {
            ForEach(displayedSongs) { song in
                SongRow(song: song, showTrackNumber: false)
                    .onTapGesture(count: 2) {
                        Task {
                            await appState.playbackManager.playNow(song)
                        }
                    }
                    .contextMenu {
                        SongContextMenu(song: song)
                    }
            }
        }
    }

    // MARK: - Search

    private func performSearch() async {
        let trimmedQuery = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = nil
            searchError = nil
            unfilteredResultCounts = SearchResultCounts()
            return
        }

        isSearching = true
        searchError = nil

        do {
            var searchResults = try await appState.networkActor.search(
                query: trimmedQuery,
                artistCount: 20,
                albumCount: 20,
                songCount: 30
            )
            unfilteredResultCounts = SearchResultCounts(
                artists: searchResults.artists.count,
                albums: searchResults.albums.count,
                songs: searchResults.songs.count
            )

            // Filter out hidden items, then apply the explicit library/global boundary.
            if let serverId = appState.activeServerId {
                let hiddenAlbumIds = (try? appState.databaseManager.loadHiddenIds(type: "album", serverId: serverId)) ?? []
                let hiddenArtistIds = (try? appState.databaseManager.loadHiddenIds(type: "artist", serverId: serverId)) ?? []
                let hiddenSongIds = (try? appState.databaseManager.loadHiddenIds(type: "song", serverId: serverId)) ?? []
                let admittedAlbumIds = searchScope == .library
                    ? ((try? appState.databaseManager.loadLibraryMemberIds(type: .album, serverId: serverId)) ?? [])
                    : []
                let admittedArtistIds = searchScope == .library
                    ? ((try? appState.databaseManager.loadLibraryMemberIds(type: .artist, serverId: serverId)) ?? [])
                    : []
                let admittedSongIds = searchScope == .library
                    ? ((try? appState.databaseManager.loadLibraryMemberIds(type: .song, serverId: serverId)) ?? [])
                    : []

                searchResults = SearchResults(
                    artists: searchResults.artists.filter {
                        !hiddenArtistIds.contains($0.id) &&
                        (searchScope == .global || admittedArtistIds.contains($0.id))
                    },
                    albums: searchResults.albums.filter {
                        !hiddenAlbumIds.contains($0.id) &&
                        (searchScope == .global || admittedAlbumIds.contains($0.id))
                    },
                    songs: searchResults.songs.filter {
                        !hiddenSongIds.contains($0.id) &&
                        (searchScope == .global || admittedSongIds.contains($0.id))
                    }
                )
            }

            results = searchResults

            // Save successful search to recent searches
            recentSearchesManager.addSearch(trimmedQuery)
        } catch let error as ResonanceError {
            searchError = error
            results = nil
            unfilteredResultCounts = SearchResultCounts()
        } catch {
            searchError = .networkError(error)
            results = nil
            unfilteredResultCounts = SearchResultCounts()
        }

        isSearching = false
    }

    private func playArtist(_ artist: Artist, shuffled: Bool = false) async {
        do {
            var songs = try await loadPlayableSongs(for: artist)
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play artist from search: \(error)")
        }
    }

    private func addArtistToQueue(_ artist: Artist) async {
        do {
            let songs = try await loadPlayableSongs(for: artist)
            for song in songs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add artist to queue from search: \(error)")
        }
    }

    private func playAlbum(_ album: Album, shuffled: Bool = false) async {
        do {
            var songs = try await loadPlayableSongs(for: album)
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play album from search: \(error)")
        }
    }

    private func addAlbumToQueue(_ album: Album) async {
        do {
            let songs = try await loadPlayableSongs(for: album)
            for song in songs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add album to queue from search: \(error)")
        }
    }

    private func loadPlayableSongs(for artist: Artist) async throws -> [Song] {
        let artistDetail = try await appState.networkActor.fetchArtist(id: artist.id)
        let admittedAlbumIds = loadLibraryMemberIds(type: .album, fallback: appState.admittedAlbumIds)
        var allSongs: [Song] = []

        for album in artistDetail.albums where searchScope == .global || admittedAlbumIds.contains(album.id) {
            let albumSongs = try await loadPlayableSongs(for: album)
            allSongs.append(contentsOf: albumSongs)
        }

        return allSongs
    }

    private func loadPlayableSongs(for album: Album) async throws -> [Song] {
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
        return songs.filter {
            !hiddenSongIds.contains($0.id) &&
            (searchScope == .global || admittedSongIds.contains($0.id))
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

    private func searchErrorMessage(_ error: ResonanceError) -> String {
        [error.errorDescription, error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

// MARK: - Search Result Section

struct SearchResultSection<Content: View>: View {
    let title: String
    var showSeeAll: Bool = false
    var onSeeAll: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if showSeeAll, let onSeeAll {
                    Button("See All") {
                        onSeeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            content()
        }
    }
}

// MARK: - Top Result Card

struct TopResultCard: View {
    @Environment(AppState.self) private var appState

    let title: String
    let subtitle: String
    let icon: String
    let coverArtId: String?
    let isCircular: Bool

    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cover art
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: icon)
                                .font(.title)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(isHovered ? 0.15 : 0.08), lineWidth: 0.5)
                )
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .task(id: coverArtId) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let coverArtId, !coverArtId.isEmpty else { return }

        // Fast path: check in-memory cache first
        if let cached = await appState.cacheActor.getArtworkImage(for: coverArtId, size: .small) {
            await MainActor.run {
                self.image = cached
            }
            return
        }

        // Fetch from server
        do {
            let data = try await appState.networkActor.fetchCoverArt(id: coverArtId, size: 200)
            try await appState.cacheActor.cacheArtworkWithImage(data, for: coverArtId, size: .small)
            if let nsImage = NSImage(data: data) {
                await MainActor.run {
                    self.image = nsImage
                }
            }
        } catch {
            // Silent failure
        }
    }
}

// MARK: - Recent Search Chip

struct RecentSearchChip: View {
    let text: String
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.subheadline)
                .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.quaternary)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
        }
        .onHover { isHovered = $0 }
        .onTapGesture {
            onTap()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Move to next line
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Backward Compatibility Section (legacy)

struct SearchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            content()
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
            .environment(AppState())
    }
}
