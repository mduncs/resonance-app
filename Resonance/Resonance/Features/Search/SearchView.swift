import SwiftUI

// MARK: - Recent Searches Manager

@MainActor
@Observable
final class RecentSearchesManager {
    private let maxItems = 10
    private let userDefaultsKey = "recentSearches"
    private let persistenceEnabled: Bool

    var recentSearches: [String] = []

    init(persistenceEnabled: Bool = !DeterministicCaptureFixture.isEnabled) {
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled {
            loadFromDefaults()
        }
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
        guard persistenceEnabled else { return }
        UserDefaults.standard.set(recentSearches, forKey: userDefaultsKey)
    }
}

// MARK: - Search View

private enum SearchScope: String, CaseIterable {
    case library = "Library"
    case global = "Global"
}

struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var pagingStore = SearchPagingStore()
    @State private var recentSearchesManager = RecentSearchesManager()
    @State private var searchScope: SearchScope = .library
    @FocusState private var isSearchFocused: Bool

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

    private var trimmedQuery: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var paging: SearchPaging { pagingStore.paging }

    private var matchedPlaylists: [Playlist] {
        guard pagingStore.hasCompletedInitialRequest, !trimmedQuery.isEmpty else { return [] }
        let normalizedQuery = trimmedQuery.lowercased()
        return appState.playlists
            .filter { $0.name.lowercased().contains(normalizedQuery) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.name.lowercased().hasPrefix(normalizedQuery)
                let rhsPrefix = rhs.name.lowercased().hasPrefix(normalizedQuery)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            if trimmedQuery.isEmpty {
                emptyStateView
            } else if pagingStore.isInitialLoading {
                InlineLoadingStatusView(title: "Searching...")
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            } else if let error = pagingStore.initialError {
                searchErrorView(error)
            } else if pagingStore.hasCompletedInitialRequest {
                let results = visibleResults(pagingStore.rawResults)
                if results.isEmpty && matchedPlaylists.isEmpty && !paging.hasMore {
                    noResultsView
                } else {
                    searchResultsView(results)
                }
            } else {
                emptyStateView
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) { searchField }
            ToolbarItem(placement: .primaryAction) { searchScopePicker }
        }
        .onChange(of: appState.shouldFocusSearch) { _, requested in
            if requested { focusSearch() }
        }
        .onAppear {
            if appState.shouldFocusSearch { focusSearch() }
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .onChange(of: appState.searchQuery) {
            resetExpandedSections()
            beginSearch(debounce: trimmedQuery.isEmpty ? nil : .milliseconds(300))
        }
        .onChange(of: searchScope) {
            resetExpandedSections()
            beginSearch()
        }
        .task(id: appState.activeServerId) {
            // A parity route can seed AppState before this view exists, so an
            // initial non-empty query does not produce an onChange event.
            // Treat it exactly like submitted production search text. A server
            // change also invalidates every offset and in-flight response.
            resetExpandedSections()
            beginSearch()
        }
        .onChange(of: pagingStore.completedInitialIdentity) { _, completed in
            guard completed == pagingStore.identity else { return }
            recentSearchesManager.addSearch(completed?.query ?? "")
        }
        .onDisappear {
            pagingStore.cancel()
        }
    }

    // MARK: - Search Field

    private func focusSearch() {
        isSearchFocused = true
        appState.shouldFocusSearch = false
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityIdentifier("Search.Query")
                .onSubmit {
                    resetExpandedSections()
                    beginSearch()
                }
                .onExitCommand {
                    query.wrappedValue = ""
                    isSearchFocused = false
                }
            if !query.wrappedValue.isEmpty {
                Button {
                    query.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("Search.Clear")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        // Native Search Response_4 field 0x7b3c085880 is597×36, font13.
        // Allow toolbar compression; its narrow-window rule is not captured.
        .frame(minWidth: 180, idealWidth: 597, maxWidth: 597)
        .frame(height: 36)
        .background(.quaternary, in: Capsule())
    }

    private var searchScopePicker: some View {
        Picker("Search scope", selection: $searchScope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .font(.system(size: 13))
        .frame(width: 163, height: 36)
        .help(searchScope == .library
            ? "Search only items admitted to your library"
            : "Search the server's full library")
        .accessibilityIdentifier("Search.Scope")
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
            action: pagingStore.retry
        )
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noResultsView: some View {
        ScrollView {
            let hasGlobalMatches = searchScope == .library && !pagingStore.rawResults.isEmpty
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

                // Playlists (server-synced collections, matched locally)
                if !matchedPlaylists.isEmpty {
                    playlistsSection(matchedPlaylists)
                }

                emptyFacetContinuationControls(results)

                if let moreError = pagingStore.moreError {
                    HStack {
                        Text(searchErrorMessage(moreError)).foregroundStyle(.secondary)
                        Button("Try Again", action: pagingStore.retry)
                            .disabled(pagingStore.isLoadingMore)
                    }
                }
            }
            // Captured catalog search: Response_4, 0x7b39ffb980.frame
            // and 0x7b39ff9b80.frame both start 34pt into their shelves.
            .padding(.horizontal, 34)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func emptyFacetContinuationControls(_ results: SearchResults) -> some View {
        let needsArtists = results.artists.isEmpty && paging.hasMoreArtists
        let needsAlbums = results.albums.isEmpty && paging.hasMoreAlbums
        let needsSongs = results.songs.isEmpty && paging.hasMoreSongs
        if needsArtists || needsAlbums || needsSongs {
            VStack(alignment: .leading, spacing: 8) {
                Text("More matches may be available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if needsArtists {
                        continuationButton(title: "Continue Artists", facet: .artists)
                    }
                    if needsAlbums {
                        continuationButton(title: "Continue Albums", facet: .albums)
                    }
                    if needsSongs {
                        continuationButton(title: "Continue Songs", facet: .songs)
                    }
                    if pagingStore.isLoadingMore {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private func continuationButton(title: String, facet: SearchPaging.Facets) -> some View {
        Button(title) { pagingStore.loadMore(facet) }
            .buttonStyle(.bordered)
            .disabled(pagingStore.isLoadingMore)
    }

    private func facetPagingControl(
        title: String,
        loadedCount: Int,
        facet: SearchPaging.Facets,
        hasMore: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(loadedCount) \(title) loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasMore {
                Button("More") { pagingStore.loadMore(facet) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(pagingStore.isLoadingMore)
            }
            if pagingStore.isLoadingMore {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Top Results Section

    private func topResultsSection(_ results: SearchResults) -> some View {
        SearchResultSection(title: "Top Results") {
            // Captured top results have two 80pt rows, at y47 and y147.
            ScrollView(.horizontal) {
                LazyHGrid(rows: [GridItem(.fixed(80), spacing: 20), GridItem(.fixed(80))], alignment: .top, spacing: 20) {
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

            }
            }
        }
    }

    // MARK: - Artists Section

    private func artistsSection(_ artists: [Artist]) -> some View {
        let displayedArtists = showAllArtists ? artists : Array(artists.prefix(displayLimit))
        let hasMore = artists.count > displayLimit || paging.hasMoreArtists

        return SearchResultSection(
            title: "Artists",
            showSeeAll: hasMore && !showAllArtists,
            onSeeAll: {
                showAllArtists = true
                pagingStore.loadMore(.artists)
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(displayedArtists) { artist in
                        NavigationLink(value: artist) {
                            VStack(alignment: .center, spacing: 12) {
                                // Native search artist focus/artwork bounds are 172pt square
                                // (Response_4, 0x7b39ff9b80.frame).
                                ArtistImageView(artistId: artist.id, coverArt: artist.coverArt)
                                .frame(width: 172, height: 172)

                                VStack(alignment: .center, spacing: 2) {
                                    Text(artist.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                }
                            }
                            .frame(width: 172, alignment: .center)
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
                if showAllArtists {
                    facetPagingControl(
                        title: "artists",
                        loadedCount: artists.count,
                        facet: .artists,
                        hasMore: paging.hasMoreArtists
                    )
                }
            }
        }
    }

    // MARK: - Albums Section

    private func albumsSection(_ albums: [Album]) -> some View {
        let displayedAlbums = showAllAlbums ? albums : Array(albums.prefix(displayLimit))
        let hasMore = albums.count > displayLimit || paging.hasMoreAlbums

        return SearchResultSection(
            title: "Albums",
            showSeeAll: hasMore && !showAllAlbums,
            onSeeAll: {
                showAllAlbums = true
                pagingStore.loadMore(.albums)
            }
        ) {
            // Native catalog results use a horizontal 200pt artwork shelf,
            // not an adaptive multi-row album grid (Response_4,
            // 0x7b39ffb980.frame and 0x7b39844f00.frame).
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(displayedAlbums) { album in
                        AlbumCardActionSurface(
                            album: album,
                            onPlay: { Task { await playAlbum(album) } }
                        ) { artworkHoverChanged in
                            NavigationLink(value: album) {
                                AlbumCard(
                                    album: album,
                                    showsHoverPlayButton: false,
                                    onArtworkHoverChange: artworkHoverChanged
                                )
                            }
                            .buttonStyle(.plain)
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
                                appState.getInfoContent = .album(album)
                            } label: {
                                Label("Get Info", systemImage: "info.circle")
                            }
                        }
                        }
                    }
                }
                if showAllAlbums {
                    facetPagingControl(
                        title: "albums",
                        loadedCount: albums.count,
                        facet: .albums,
                        hasMore: paging.hasMoreAlbums
                    )
                }
            }
        }
    }

    // MARK: - Songs Section

    private func songsSection(_ songs: [Song]) -> some View {
        let displayedSongs = showAllSongs ? songs : Array(songs.prefix(displayLimit))
        let hasMore = songs.count > displayLimit || paging.hasMoreSongs

        return SearchResultSection(
            title: "Songs",
            showSeeAll: hasMore && !showAllSongs,
            onSeeAll: {
                showAllSongs = true
                pagingStore.loadMore(.songs)
            }
        ) {
            // Response_4: three song rows advance by 56pt; adjacent columns
            // start at x34 and x473, with 419pt-wide row focus bounds.
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 0), count: 3), spacing: 20) {
                        ForEach(Array(displayedSongs.enumerated()), id: \.element.id) { index, song in
                        SearchSongResultRow(
                            song: song,
                            showsSeparator: index % 3 < 2 && index + 1 < displayedSongs.count
                        )
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
                    .frame(height: 174, alignment: .top)
                }
                if showAllSongs {
                    facetPagingControl(
                        title: "songs",
                        loadedCount: songs.count,
                        facet: .songs,
                        hasMore: paging.hasMoreSongs
                    )
                }
            }
        }
    }

    // MARK: - Playlists Section

    private func playlistsSection(_ playlists: [Playlist]) -> some View {
        SearchResultSection(title: "Playlists") {
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    PlaylistRow(playlist: playlist)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    PlaylistContextMenu(playlist: playlist)
                }
            }
        }
    }

    // MARK: - Search

    private func resetExpandedSections() {
        showAllArtists = false
        showAllAlbums = false
        showAllSongs = false
    }

    private func beginSearch(debounce: Duration? = nil) {
        let query = trimmedQuery
        let scope = searchScope.rawValue.lowercased()
        let serverID = appState.activeServerId ?? ""
        pagingStore.begin(
            query: query,
            scope: scope,
            serverID: serverID,
            debounce: debounce
        ) { request in
            guard let expectedServerID = UUID(uuidString: request.identity.serverID) else {
                throw ResonanceError.notConfigured
            }
            let facets = request.facets
            return try await appState.networkActor.search(
                query: request.identity.query,
                artistCount: facets.contains(.artists) ? 100 : 0,
                albumCount: facets.contains(.albums) ? 100 : 0,
                songCount: facets.contains(.songs) ? 100 : 0,
                artistOffset: request.artistOffset,
                albumOffset: request.albumOffset,
                songOffset: request.songOffset,
                expectedServerID: expectedServerID
            )
        }
    }

    private func visibleResults(_ raw: SearchResults) -> SearchResults {
        // Establish an Observation dependency even when a publication happens
        // to replace an admitted-ID set with an equal value.
        _ = appState.libraryMembershipRevision
        return SearchResultVisibility(
            libraryOnly: searchScope == .library,
            admittedArtistIDs: appState.admittedArtistIds,
            admittedAlbumIDs: appState.admittedAlbumIds,
            admittedSongIDs: appState.admittedSongIds,
            hiddenArtistIDs: appState.hiddenArtistIds,
            hiddenAlbumIDs: appState.hiddenAlbumIds,
            hiddenSongIDs: appState.hiddenSongIds
        ).project(raw)
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
        let serverIdentity = (
            id: appState.activeServer?.id,
            url: appState.activeServer?.url,
            username: appState.activeServer?.username
        )
        do {
            var songs = try await loadPlayableSongs(for: album)
            guard !Task.isCancelled,
                  appState.activeServer?.id == serverIdentity.id,
                  appState.activeServer?.url == serverIdentity.url,
                  appState.activeServer?.username == serverIdentity.username else { return }
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch is CancellationError {
            // Server changes invalidate the active result fetch.
        } catch {
            guard !Task.isCancelled,
                  appState.activeServer?.id == serverIdentity.id,
                  appState.activeServer?.url == serverIdentity.url,
                  appState.activeServer?.username == serverIdentity.username else { return }
            appState.showFeedback(
                message: "Couldn't play \(album.name)",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
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

// MARK: - Search Song Result

private struct SearchSongResultRow: View {
    let song: Song
    let showsSeparator: Bool

    var body: some View {
        // Native Response_4 layers: 0x7b3c65af40 artwork,
        // 0x7b3d5951f0 / 0x7b3d595260 text, 0x7b4fb12a00 menu.
        // Text bounds are raster extents, not evidence of point size/weight.
        ZStack(alignment: .topLeading) {
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(song.title)
                .font(.body)
                .lineLimit(1)
                .frame(width: 311, height: 16, alignment: .leading)
                .offset(x: 60, y: 8)

            Text(song.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 311, height: 16, alignment: .leading)
                .offset(x: 60, y: 24)

            Menu {
                SongContextMenu(song: song)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20, height: 14)
            .offset(x: 389, y: 17)
            .accessibilityLabel("More actions for \(song.title)")

            if showsSeparator {
                // 0x7b3c65a520: [359,1] at [94,52], artwork origin x34.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 359, height: 1)
                    .offset(x: 60, y: 52)
            }
        }
        .frame(width: 419, height: 56, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(song.title) by \(song.artist), \(song.formattedDuration)\(song.isExplicit ? ", explicit" : "")")
        .accessibilityHint("Double-click to play; open More Actions for song commands")
        .help("\(song.title) — \(song.artist) — \(song.formattedDuration)")
    }
}

// MARK: - Top Result Card

struct TopResultCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let icon: String
    let coverArtId: String?
    let isCircular: Bool

    @State private var image: NSImage?

    var body: some View {
        // Native catalog-search Response_4: card 0x7b3c7d7b20,
        // artwork 0x7b3c7d7fe0, title/subtitle 0x7b3d596e60 / 0x7b3d594380.
        // Their layer anchors are zero, so these are card-local top-left offsets.
        ZStack(alignment: .topLeading) {
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
            .frame(width: 42, height: 42)
            .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
            .offset(x: 14, y: 19)

            // The capture exposes raster drawing bounds, not font descriptors.
            // Retain existing semantic fonts; do not infer point sizes from pixels.
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(width: 192, height: 19, alignment: .leading)
                .offset(x: 68, y: 22)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 192, height: 15, alignment: .leading)
                .offset(x: 68, y: 43)

            Image(systemName: "chevron.right")
                .resizable()
                .frame(width: 5, height: 9)
                .foregroundStyle(.secondary)
                .offset(x: 276, y: 36)
                .accessibilityHidden(true)
        }
        .frame(width: 292, height: 80, alignment: .topLeading)
        .background {
            // Only dark is evidenced; retain the existing material in light.
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.sRGB, red: 53 / 255, green: 53 / 255, blue: 53 / 255))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
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
